//! Pairing-only QUIC endpoint. Connections from this type never enter Repo transport.

use std::{
    fmt,
    net::SocketAddr,
    sync::{Arc, Mutex},
};

use quinn::{Connection, Endpoint, RecvStream, SendStream};
use rustls::{
    CertificateError, DigitallySignedStruct, DistinguishedName, Error as TlsError, SignatureScheme,
    client::danger::{HandshakeSignatureValid, ServerCertVerified, ServerCertVerifier},
    crypto::{CryptoProvider, verify_tls12_signature, verify_tls13_signature},
    pki_types::{CertificateDer, ServerName, UnixTime},
    server::danger::{ClientCertVerified, ClientCertVerifier},
};
use tokio::io::AsyncReadExt;

use crate::{
    identity::{DeviceIdentity, PublicDeviceKey},
    pairing::{PAIRING_ALPN, PairingError, PairingMessage},
    quinn_transport::{TlsIdentity, extract_public_key, peer_certificate},
};

const EXPORTER_LABEL: &[u8] = b"EXPORTER-fi-pair-v1";
const MAX_WIRE_MESSAGE: usize = 1024;

/// Application close code for an orderly close: pairing completed, stopped,
/// or timed out.
const CLOSE_CODE_DONE: u32 = 0;
/// Application close code for "I cannot take this connection right now". The
/// dialer maps it to [`PairingError::PeerBusy`] and keeps its own window.
const CLOSE_CODE_BUSY: u32 = 1;

#[derive(Debug)]
struct StructuralServerVerifier {
    provider: Arc<CryptoProvider>,
}

impl ServerCertVerifier for StructuralServerVerifier {
    fn verify_server_cert(
        &self,
        end_entity: &CertificateDer<'_>,
        intermediates: &[CertificateDer<'_>],
        _server_name: &ServerName<'_>,
        _ocsp: &[u8],
        _now: UnixTime,
    ) -> Result<ServerCertVerified, TlsError> {
        if !intermediates.is_empty() || extract_public_key(end_entity).is_err() {
            return Err(TlsError::InvalidCertificate(CertificateError::BadEncoding));
        }
        Ok(ServerCertVerified::assertion())
    }
    fn verify_tls12_signature(
        &self,
        message: &[u8],
        cert: &CertificateDer<'_>,
        dss: &DigitallySignedStruct,
    ) -> Result<HandshakeSignatureValid, TlsError> {
        verify_tls12_signature(
            message,
            cert,
            dss,
            &self.provider.signature_verification_algorithms,
        )
    }
    fn verify_tls13_signature(
        &self,
        message: &[u8],
        cert: &CertificateDer<'_>,
        dss: &DigitallySignedStruct,
    ) -> Result<HandshakeSignatureValid, TlsError> {
        verify_tls13_signature(
            message,
            cert,
            dss,
            &self.provider.signature_verification_algorithms,
        )
    }
    fn supported_verify_schemes(&self) -> Vec<SignatureScheme> {
        self.provider
            .signature_verification_algorithms
            .supported_schemes()
    }
}

struct StructuralClientVerifier {
    provider: Arc<CryptoProvider>,
    hints: Vec<DistinguishedName>,
}

impl fmt::Debug for StructuralClientVerifier {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str("StructuralClientVerifier")
    }
}

impl ClientCertVerifier for StructuralClientVerifier {
    fn root_hint_subjects(&self) -> &[DistinguishedName] {
        &self.hints
    }
    fn verify_client_cert(
        &self,
        end_entity: &CertificateDer<'_>,
        intermediates: &[CertificateDer<'_>],
        _now: UnixTime,
    ) -> Result<ClientCertVerified, TlsError> {
        if !intermediates.is_empty() || extract_public_key(end_entity).is_err() {
            return Err(TlsError::InvalidCertificate(CertificateError::BadEncoding));
        }
        Ok(ClientCertVerified::assertion())
    }
    fn verify_tls12_signature(
        &self,
        message: &[u8],
        cert: &CertificateDer<'_>,
        dss: &DigitallySignedStruct,
    ) -> Result<HandshakeSignatureValid, TlsError> {
        verify_tls12_signature(
            message,
            cert,
            dss,
            &self.provider.signature_verification_algorithms,
        )
    }
    fn verify_tls13_signature(
        &self,
        message: &[u8],
        cert: &CertificateDer<'_>,
        dss: &DigitallySignedStruct,
    ) -> Result<HandshakeSignatureValid, TlsError> {
        verify_tls13_signature(
            message,
            cert,
            dss,
            &self.provider.signature_verification_algorithms,
        )
    }
    fn supported_verify_schemes(&self) -> Vec<SignatureScheme> {
        self.provider
            .signature_verification_algorithms
            .supported_schemes()
    }
}

#[derive(Clone)]
pub struct PairingConnection {
    connection: Connection,
    peer_public_key: PublicDeviceKey,
}

impl fmt::Debug for PairingConnection {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("PairingConnection")
            .field("remote", &self.connection.remote_address())
            .finish_non_exhaustive()
    }
}

impl PairingConnection {
    #[must_use]
    pub const fn peer_public_key(&self) -> PublicDeviceKey {
        self.peer_public_key
    }
    #[must_use]
    pub fn remote_address(&self) -> SocketAddr {
        self.connection.remote_address()
    }
    pub fn exporter(&self, transcript_hash: &[u8]) -> Result<[u8; 32], PairingError> {
        let mut output = [0; 32];
        self.connection
            .export_keying_material(&mut output, EXPORTER_LABEL, transcript_hash)
            .map_err(|_| PairingError::Authentication)?;
        Ok(output)
    }
    pub async fn open_stream(&self) -> Result<PairingStream, PairingError> {
        let (send, recv) = self
            .connection
            .open_bi()
            .await
            .map_err(|error| PairingError::Transport(error.to_string()))?;
        Ok(PairingStream { send, recv })
    }
    pub async fn accept_stream(&self) -> Result<PairingStream, PairingError> {
        let (send, recv) = self
            .connection
            .accept_bi()
            .await
            .map_err(|error| PairingError::Transport(error.to_string()))?;
        Ok(PairingStream { send, recv })
    }
    pub fn close(&self) {
        self.connection
            .close(CLOSE_CODE_DONE.into(), b"pairing complete");
    }
    /// Closes an inbound connection the local device cannot accept right now,
    /// with a reason the dialer can distinguish from a failure.
    pub fn refuse(&self) {
        self.connection
            .close(CLOSE_CODE_BUSY.into(), b"pairing busy");
    }
    /// Returns `PeerBusy` when the peer closed this connection with the busy
    /// code; `None` when it is open or closed for any other reason.
    #[must_use]
    pub fn peer_refusal(&self) -> Option<PairingError> {
        match self.connection.close_reason()? {
            quinn::ConnectionError::ApplicationClosed(close)
                if close.error_code == quinn::VarInt::from_u32(CLOSE_CODE_BUSY) =>
            {
                Some(PairingError::PeerBusy)
            }
            _ => None,
        }
    }
}

pub struct PairingStream {
    send: SendStream,
    recv: RecvStream,
}

impl PairingStream {
    pub async fn send(&mut self, message: &PairingMessage) -> Result<(), PairingError> {
        let bytes = message.encode()?;
        let len =
            u16::try_from(bytes.len()).map_err(|_| PairingError::Malformed("message too large"))?;
        self.send
            .write_all(&len.to_be_bytes())
            .await
            .map_err(|error| PairingError::Transport(error.to_string()))?;
        self.send
            .write_all(&bytes)
            .await
            .map_err(|error| PairingError::Transport(error.to_string()))?;
        Ok(())
    }
    pub async fn receive(&mut self) -> Result<PairingMessage, PairingError> {
        let len = usize::from(
            self.recv
                .read_u16()
                .await
                .map_err(|error| PairingError::Transport(error.to_string()))?,
        );
        if len == 0 || len > MAX_WIRE_MESSAGE {
            return Err(PairingError::Malformed("invalid message size"));
        }
        let mut bytes = vec![0; len];
        self.recv
            .read_exact(&mut bytes)
            .await
            .map_err(|error| PairingError::Transport(error.to_string()))?;
        PairingMessage::decode(&bytes)
    }
    pub fn finish(&mut self) -> Result<(), PairingError> {
        self.send
            .finish()
            .map_err(|error| PairingError::Transport(error.to_string()))
    }
}

pub struct PairingTransport {
    endpoint: Endpoint,
    server_config: quinn::ServerConfig,
    client_config: quinn::ClientConfig,
    connections: Mutex<Vec<Connection>>,
}

impl fmt::Debug for PairingTransport {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("PairingTransport")
            .field("local_addr", &self.local_addr().ok())
            .finish_non_exhaustive()
    }
}

impl PairingTransport {
    pub fn bind(bind: SocketAddr, identity: &DeviceIdentity) -> Result<Self, PairingError> {
        let tls_identity = TlsIdentity::generate(identity)
            .map_err(|error| PairingError::Transport(error.to_string()))?;
        let provider = Arc::new(rustls::crypto::ring::default_provider());
        let mut server_tls = rustls::ServerConfig::builder_with_provider(provider.clone())
            .with_protocol_versions(&[&rustls::version::TLS13])
            .map_err(|error| PairingError::Transport(error.to_string()))?
            .with_client_cert_verifier(Arc::new(StructuralClientVerifier {
                provider: provider.clone(),
                hints: Vec::new(),
            }))
            .with_single_cert(
                vec![tls_identity.certificate.clone()],
                tls_identity.private_key(),
            )
            .map_err(|error| PairingError::Transport(error.to_string()))?;
        server_tls.alpn_protocols = vec![PAIRING_ALPN.to_vec()];
        let server_crypto = quinn::crypto::rustls::QuicServerConfig::try_from(server_tls)
            .map_err(|error| PairingError::Transport(error.to_string()))?;
        let server_config = quinn::ServerConfig::with_crypto(Arc::new(server_crypto));
        let mut client_tls = rustls::ClientConfig::builder_with_provider(provider.clone())
            .with_protocol_versions(&[&rustls::version::TLS13])
            .map_err(|error| PairingError::Transport(error.to_string()))?
            .dangerous()
            .with_custom_certificate_verifier(Arc::new(StructuralServerVerifier { provider }))
            .with_client_auth_cert(
                vec![tls_identity.certificate.clone()],
                tls_identity.private_key(),
            )
            .map_err(|error| PairingError::Transport(error.to_string()))?;
        client_tls.alpn_protocols = vec![PAIRING_ALPN.to_vec()];
        let client_crypto = quinn::crypto::rustls::QuicClientConfig::try_from(client_tls)
            .map_err(|error| PairingError::Transport(error.to_string()))?;
        let endpoint =
            Endpoint::client(bind).map_err(|error| PairingError::Transport(error.to_string()))?;
        Ok(Self {
            endpoint,
            server_config,
            client_config: quinn::ClientConfig::new(Arc::new(client_crypto)),
            connections: Mutex::new(Vec::new()),
        })
    }
    pub fn local_addr(&self) -> Result<SocketAddr, PairingError> {
        self.endpoint
            .local_addr()
            .map_err(|error| PairingError::Transport(error.to_string()))
    }
    pub fn start(&self) {
        self.endpoint
            .set_server_config(Some(self.server_config.clone()));
    }
    pub fn stop(&self) {
        self.endpoint.set_server_config(None);
        if let Ok(mut connections) = self.connections.lock() {
            for connection in connections.drain(..) {
                connection.close(CLOSE_CODE_DONE.into(), b"pairing inactive");
            }
        }
    }
    pub fn deactivate_listener(&self) {
        self.endpoint.set_server_config(None);
    }
    pub async fn accept(&self) -> Result<PairingConnection, PairingError> {
        let incoming = self.endpoint.accept().await.ok_or(PairingError::Inactive)?;
        let connection = incoming
            .await
            .map_err(|error| PairingError::Transport(error.to_string()))?;
        let peer_public_key = extract_public_key(
            &peer_certificate(&connection)
                .map_err(|error| PairingError::Transport(error.to_string()))?,
        )
        .map_err(|error| PairingError::Transport(error.to_string()))?;
        self.connections
            .lock()
            .map_err(|_| PairingError::Transport("connection lock poisoned".into()))?
            .push(connection.clone());
        Ok(PairingConnection {
            connection,
            peer_public_key,
        })
    }
    pub async fn connect(&self, address: SocketAddr) -> Result<PairingConnection, PairingError> {
        let connection = self
            .endpoint
            .connect_with(self.client_config.clone(), address, "fi.invalid")
            .map_err(|error| PairingError::Transport(error.to_string()))?
            .await
            .map_err(|error| PairingError::Transport(error.to_string()))?;
        let peer_public_key = extract_public_key(
            &peer_certificate(&connection)
                .map_err(|error| PairingError::Transport(error.to_string()))?,
        )
        .map_err(|error| PairingError::Transport(error.to_string()))?;
        self.connections
            .lock()
            .map_err(|_| PairingError::Transport("connection lock poisoned".into()))?
            .push(connection.clone());
        Ok(PairingConnection {
            connection,
            peer_public_key,
        })
    }
}
