//! Authenticated Quinn implementation of the repository transport port.

use std::{
    collections::HashMap,
    fmt,
    net::SocketAddr,
    sync::{
        Arc, Mutex, RwLock, Weak,
        atomic::{AtomicBool, AtomicU64, Ordering},
    },
};

use async_trait::async_trait;
use automerge_repo::{
    PeerId,
    error::NetworkError,
    network::{NetworkEvent, NetworkTransport},
    protocol::MAX_BODY_LEN,
};
use bytes::Bytes;
use ed25519_dalek::pkcs8::EncodePrivateKey;
use quinn::{Connection, Endpoint, RecvStream, SendStream};
use rcgen::{CertificateParams, KeyPair, PKCS_ED25519};
use rustls::{
    CertificateError, DigitallySignedStruct, DistinguishedName, Error as TlsError, SignatureScheme,
    client::danger::{HandshakeSignatureValid, ServerCertVerified, ServerCertVerifier},
    crypto::{CryptoProvider, verify_tls12_signature, verify_tls13_signature},
    pki_types::{CertificateDer, PrivateKeyDer, PrivatePkcs8KeyDer, ServerName, UnixTime},
    server::danger::{ClientCertVerified, ClientCertVerifier},
};
use tokio::{
    io::{AsyncRead, AsyncReadExt},
    sync::mpsc,
    task::JoinHandle,
};
use x509_parser::prelude::{FromDer, X509Certificate};

use crate::{
    adapters::SqliteControlStore,
    control::{PeerTrustRecord, TrustState},
    identity::{DeviceId, DeviceIdentity, PublicDeviceKey},
    routing::{
        ConnectionDirection, ConnectionFailure, NetworkEndpoint, PeerConnector, SessionCandidate,
        choose_session,
    },
};

pub const SYNC_ALPN: &[u8] = b"myapp-sync/1";
const STREAM_PREFACE: &[u8] = b"FISYNC\x01";
const FRAME_PREFIX_LEN: usize = 4;
const FRAME_BODY_HEADER_LEN: usize = 8;
const FRAME_MAGIC: &[u8; 4] = b"FIRP";

#[derive(Clone, Debug, thiserror::Error, Eq, PartialEq)]
pub enum QuinnTransportError {
    #[error("identity certificate is malformed")]
    MalformedCertificate,
    #[error("identity certificate does not contain an Ed25519 public key")]
    WrongPublicKeyAlgorithm,
    #[error("identity certificate signature is invalid")]
    InvalidCertificateSignature,
    #[error("peer {0} is unknown")]
    UnknownPeer(DeviceId),
    #[error("peer {0} is revoked")]
    RevokedPeer(DeviceId),
    #[error("peer {0} presented a key that does not match its trust record")]
    KeyMismatch(DeviceId),
    #[error("QUIC configuration failed: {0}")]
    Configuration(String),
    #[error("QUIC connection failed: {0}")]
    Connection(String),
    #[error("sync stream failed: {0}")]
    Stream(String),
    #[error("sync stream protocol violation: {0}")]
    Protocol(&'static str),
    #[error("transport is closed")]
    Closed,
}

pub trait TrustResolver: Send + Sync + 'static {
    fn peer_trust(&self, device: DeviceId) -> Result<Option<PeerTrustRecord>, String>;
}

impl TrustResolver for SqliteControlStore {
    fn peer_trust(&self, device: DeviceId) -> Result<Option<PeerTrustRecord>, String> {
        SqliteControlStore::peer_trust(self, device).map_err(|error| error.to_string())
    }
}

#[derive(Debug, Default)]
pub struct MemoryTrustResolver(RwLock<HashMap<DeviceId, PeerTrustRecord>>);

impl MemoryTrustResolver {
    pub fn set(&self, record: PeerTrustRecord) {
        self.0
            .write()
            .expect("trust lock poisoned")
            .insert(record.device_id, record);
    }
}

impl TrustResolver for MemoryTrustResolver {
    fn peer_trust(&self, device: DeviceId) -> Result<Option<PeerTrustRecord>, String> {
        Ok(self
            .0
            .read()
            .map_err(|_| "trust lock poisoned")?
            .get(&device)
            .cloned())
    }
}

pub struct TlsIdentity {
    pub certificate: CertificateDer<'static>,
    private_key: PrivatePkcs8KeyDer<'static>,
}

impl fmt::Debug for TlsIdentity {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter
            .debug_struct("TlsIdentity")
            .field("certificate", &"[DER]")
            .field("private_key", &"[REDACTED]")
            .finish()
    }
}

impl TlsIdentity {
    pub fn generate(identity: &DeviceIdentity) -> Result<Self, QuinnTransportError> {
        let signing_key = identity.private_key().signing_key();
        let pkcs8 = signing_key
            .to_pkcs8_der()
            .map_err(|error| QuinnTransportError::Configuration(error.to_string()))?;
        let private_key = PrivatePkcs8KeyDer::from(pkcs8.as_bytes().to_vec());
        let key_pair = KeyPair::from_pkcs8_der_and_sign_algo(&private_key, &PKCS_ED25519)
            .map_err(|error| QuinnTransportError::Configuration(error.to_string()))?;
        let mut params = CertificateParams::new(vec!["fi.invalid".into()])
            .map_err(|error| QuinnTransportError::Configuration(error.to_string()))?;
        params
            .distinguished_name
            .push(rcgen::DnType::CommonName, identity.id().to_string());
        let certificate = params
            .self_signed(&key_pair)
            .map_err(|error| QuinnTransportError::Configuration(error.to_string()))?;
        let certificate = CertificateDer::from(certificate.der().to_vec());
        let extracted = extract_public_key(&certificate)?;
        if !extracted.constant_time_eq(&identity.public_key()) {
            return Err(QuinnTransportError::KeyMismatch(identity.id()));
        }
        Ok(Self {
            certificate,
            private_key,
        })
    }

    pub(crate) fn private_key(&self) -> PrivateKeyDer<'static> {
        PrivateKeyDer::Pkcs8(self.private_key.clone_key())
    }
}

pub fn extract_public_key(
    certificate: &CertificateDer<'_>,
) -> Result<PublicDeviceKey, QuinnTransportError> {
    let (remainder, parsed) = X509Certificate::from_der(certificate.as_ref())
        .map_err(|_| QuinnTransportError::MalformedCertificate)?;
    if !remainder.is_empty() {
        return Err(QuinnTransportError::MalformedCertificate);
    }
    parsed
        .verify_signature(None)
        .map_err(|_| QuinnTransportError::InvalidCertificateSignature)?;
    let public = parsed.public_key();
    if public.algorithm.algorithm.to_id_string() != "1.3.101.112"
        || public.algorithm.parameters.is_some()
        || public.subject_public_key.unused_bits != 0
    {
        return Err(QuinnTransportError::WrongPublicKeyAlgorithm);
    }
    let bytes: [u8; 32] = public
        .subject_public_key
        .data
        .as_ref()
        .try_into()
        .map_err(|_| QuinnTransportError::MalformedCertificate)?;
    PublicDeviceKey::from_bytes(bytes).map_err(|_| QuinnTransportError::MalformedCertificate)
}

fn authenticate(
    certificate: &CertificateDer<'_>,
    trust: &dyn TrustResolver,
) -> Result<DeviceId, QuinnTransportError> {
    let public_key = extract_public_key(certificate)?;
    let device = DeviceId::from_public_key(public_key.as_bytes());
    let record = trust
        .peer_trust(device)
        .map_err(QuinnTransportError::Configuration)?
        .ok_or(QuinnTransportError::UnknownPeer(device))?;
    if record.state == TrustState::Revoked {
        return Err(QuinnTransportError::RevokedPeer(device));
    }
    if !record.public_key.constant_time_eq(&public_key) {
        return Err(QuinnTransportError::KeyMismatch(device));
    }
    Ok(device)
}

fn tls_error(error: QuinnTransportError) -> TlsError {
    match error {
        QuinnTransportError::MalformedCertificate
        | QuinnTransportError::WrongPublicKeyAlgorithm
        | QuinnTransportError::InvalidCertificateSignature => {
            TlsError::InvalidCertificate(CertificateError::BadEncoding)
        }
        QuinnTransportError::RevokedPeer(_) => {
            TlsError::InvalidCertificate(CertificateError::Revoked)
        }
        QuinnTransportError::UnknownPeer(_) => {
            TlsError::InvalidCertificate(CertificateError::UnknownIssuer)
        }
        _ => TlsError::InvalidCertificate(CertificateError::ApplicationVerificationFailure),
    }
}

#[derive(Debug)]
struct PinnedServerVerifier {
    expected: PeerTrustRecord,
    provider: Arc<CryptoProvider>,
}

impl ServerCertVerifier for PinnedServerVerifier {
    fn verify_server_cert(
        &self,
        end_entity: &CertificateDer<'_>,
        intermediates: &[CertificateDer<'_>],
        _server_name: &ServerName<'_>,
        _ocsp: &[u8],
        _now: UnixTime,
    ) -> Result<ServerCertVerified, TlsError> {
        if !intermediates.is_empty() {
            return Err(TlsError::InvalidCertificate(CertificateError::BadEncoding));
        }
        let key = extract_public_key(end_entity).map_err(tls_error)?;
        if self.expected.state == TrustState::Revoked {
            return Err(tls_error(QuinnTransportError::RevokedPeer(
                self.expected.device_id,
            )));
        }
        if !key.constant_time_eq(&self.expected.public_key)
            || !DeviceId::from_public_key(key.as_bytes()).constant_time_eq(&self.expected.device_id)
        {
            return Err(tls_error(QuinnTransportError::KeyMismatch(
                self.expected.device_id,
            )));
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

struct TrustedClientVerifier {
    trust: Arc<dyn TrustResolver>,
    provider: Arc<CryptoProvider>,
    hints: Vec<DistinguishedName>,
}

impl fmt::Debug for TrustedClientVerifier {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str("TrustedClientVerifier")
    }
}

impl ClientCertVerifier for TrustedClientVerifier {
    fn root_hint_subjects(&self) -> &[DistinguishedName] {
        &self.hints
    }

    fn verify_client_cert(
        &self,
        end_entity: &CertificateDer<'_>,
        intermediates: &[CertificateDer<'_>],
        _now: UnixTime,
    ) -> Result<ClientCertVerified, TlsError> {
        if !intermediates.is_empty() {
            return Err(TlsError::InvalidCertificate(CertificateError::BadEncoding));
        }
        authenticate(end_entity, self.trust.as_ref()).map_err(tls_error)?;
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

#[derive(Clone, Debug)]
pub struct QuinnTransportConfig {
    pub event_capacity: usize,
    pub writer_capacity: usize,
    pub max_connections: usize,
}

impl Default for QuinnTransportConfig {
    fn default() -> Self {
        Self {
            event_capacity: 128,
            writer_capacity: 32,
            max_connections: 64,
        }
    }
}

struct UnauthenticatedConnection {
    connection: Connection,
}

struct AuthenticatedConnection {
    device: DeviceId,
    direction: ConnectionDirection,
    connection: Connection,
}

impl UnauthenticatedConnection {
    fn authenticate(
        self,
        trust: &dyn TrustResolver,
        direction: ConnectionDirection,
    ) -> Result<AuthenticatedConnection, QuinnTransportError> {
        let certificate = peer_certificate(&self.connection)?;
        let device = authenticate(&certificate, trust)?;
        Ok(AuthenticatedConnection {
            device,
            direction,
            connection: self.connection,
        })
    }
}

struct Session {
    generation: u64,
    direction: ConnectionDirection,
    connection: Connection,
    writer: mpsc::Sender<Bytes>,
}

pub struct QuinnTransport {
    self_weak: Weak<QuinnTransport>,
    endpoint: Endpoint,
    identity: Arc<DeviceIdentity>,
    tls_identity: TlsIdentity,
    trust: Arc<dyn TrustResolver>,
    config: QuinnTransportConfig,
    events_tx: mpsc::Sender<NetworkEvent>,
    events_rx: Mutex<Option<mpsc::Receiver<NetworkEvent>>>,
    sessions: Mutex<HashMap<PeerId, Session>>,
    generation: AtomicU64,
    closed: AtomicBool,
    tasks: Mutex<Vec<JoinHandle<()>>>,
}

impl fmt::Debug for QuinnTransport {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter
            .debug_struct("QuinnTransport")
            .field("local_addr", &self.endpoint.local_addr().ok())
            .field("device_id", &self.identity.id())
            .field("closed", &self.closed.load(Ordering::Acquire))
            .finish_non_exhaustive()
    }
}

impl QuinnTransport {
    pub fn bind(
        bind: SocketAddr,
        identity: Arc<DeviceIdentity>,
        trust: Arc<dyn TrustResolver>,
        config: QuinnTransportConfig,
    ) -> Result<Arc<Self>, QuinnTransportError> {
        if config.event_capacity == 0 || config.writer_capacity == 0 || config.max_connections == 0
        {
            return Err(QuinnTransportError::Configuration(
                "all transport capacities must be greater than zero".into(),
            ));
        }
        let provider = Arc::new(rustls::crypto::ring::default_provider());
        let tls_identity = TlsIdentity::generate(&identity)?;
        let verifier = TrustedClientVerifier {
            trust: trust.clone(),
            provider: provider.clone(),
            hints: Vec::new(),
        };
        let mut tls = rustls::ServerConfig::builder_with_provider(provider)
            .with_protocol_versions(&[&rustls::version::TLS13])
            .map_err(|error| QuinnTransportError::Configuration(error.to_string()))?
            .with_client_cert_verifier(Arc::new(verifier))
            .with_single_cert(
                vec![tls_identity.certificate.clone()],
                tls_identity.private_key(),
            )
            .map_err(|error| QuinnTransportError::Configuration(error.to_string()))?;
        tls.alpn_protocols = vec![SYNC_ALPN.to_vec()];
        let crypto = quinn::crypto::rustls::QuicServerConfig::try_from(tls)
            .map_err(|error| QuinnTransportError::Configuration(error.to_string()))?;
        let mut server = quinn::ServerConfig::with_crypto(Arc::new(crypto));
        let transport =
            Arc::get_mut(&mut server.transport).expect("new transport config is unique");
        transport
            .max_concurrent_bidi_streams(1_u8.into())
            .max_concurrent_uni_streams(0_u8.into())
            .datagram_receive_buffer_size(None)
            .datagram_send_buffer_size(0);
        let endpoint = Endpoint::server(server, bind)
            .map_err(|error| QuinnTransportError::Configuration(error.to_string()))?;
        let (events_tx, events_rx) = mpsc::channel(config.event_capacity);
        let transport = Arc::new_cyclic(|self_weak| Self {
            self_weak: self_weak.clone(),
            endpoint,
            identity,
            tls_identity,
            trust,
            config,
            events_tx,
            events_rx: Mutex::new(Some(events_rx)),
            sessions: Mutex::new(HashMap::new()),
            generation: AtomicU64::new(0),
            closed: AtomicBool::new(false),
            tasks: Mutex::new(Vec::new()),
        });
        let owner = transport.clone();
        let task = tokio::spawn(async move { owner.accept_loop().await });
        transport.track_task(task);
        Ok(transport)
    }

    pub fn local_addr(&self) -> Result<SocketAddr, QuinnTransportError> {
        self.endpoint
            .local_addr()
            .map_err(|error| QuinnTransportError::Configuration(error.to_string()))
    }

    fn client_config(
        &self,
        expected: PeerTrustRecord,
    ) -> Result<quinn::ClientConfig, QuinnTransportError> {
        let provider = Arc::new(rustls::crypto::ring::default_provider());
        let verifier = PinnedServerVerifier {
            expected,
            provider: provider.clone(),
        };
        let mut tls = rustls::ClientConfig::builder_with_provider(provider)
            .with_protocol_versions(&[&rustls::version::TLS13])
            .map_err(|error| QuinnTransportError::Configuration(error.to_string()))?
            .dangerous()
            .with_custom_certificate_verifier(Arc::new(verifier))
            .with_client_auth_cert(
                vec![self.tls_identity.certificate.clone()],
                self.tls_identity.private_key(),
            )
            .map_err(|error| QuinnTransportError::Configuration(error.to_string()))?;
        tls.alpn_protocols = vec![SYNC_ALPN.to_vec()];
        let crypto = quinn::crypto::rustls::QuicClientConfig::try_from(tls)
            .map_err(|error| QuinnTransportError::Configuration(error.to_string()))?;
        Ok(quinn::ClientConfig::new(Arc::new(crypto)))
    }

    async fn accept_loop(self: Arc<Self>) {
        while !self.closed.load(Ordering::Acquire) {
            let Some(incoming) = self.endpoint.accept().await else {
                break;
            };
            if self.endpoint.open_connections() >= self.config.max_connections {
                incoming.refuse();
                continue;
            }
            let owner = self.clone();
            let task = tokio::spawn(async move {
                let Ok(connection) = incoming.await else {
                    return;
                };
                let unauthenticated = UnauthenticatedConnection { connection };
                let Ok(authenticated) = unauthenticated
                    .authenticate(owner.trust.as_ref(), ConnectionDirection::Inbound)
                else {
                    return;
                };
                let connection = authenticated.connection.clone();
                let Ok((mut send, mut receive)) = connection.accept_bi().await else {
                    return;
                };
                if read_preface(&mut receive).await.is_err() {
                    connection.close(1_u32.into(), b"invalid sync preface");
                    return;
                }
                if send.write_all(STREAM_PREFACE).await.is_err() {
                    connection.close(1_u32.into(), b"sync preface failed");
                    return;
                }
                let _ = owner.register(authenticated, send, receive).await;
            });
            self.track_task(task);
        }
    }

    pub async fn dial(
        &self,
        peer: DeviceId,
        address: SocketAddr,
    ) -> Result<u64, QuinnTransportError> {
        if self.closed.load(Ordering::Acquire) {
            return Err(QuinnTransportError::Closed);
        }
        let expected = self
            .trust
            .peer_trust(peer)
            .map_err(QuinnTransportError::Configuration)?
            .ok_or(QuinnTransportError::UnknownPeer(peer))?;
        if expected.state == TrustState::Revoked {
            return Err(QuinnTransportError::RevokedPeer(peer));
        }
        let connecting = self
            .endpoint
            .connect_with(self.client_config(expected)?, address, "fi.invalid")
            .map_err(|error| QuinnTransportError::Connection(error.to_string()))?;
        let connection = connecting
            .await
            .map_err(|error| QuinnTransportError::Connection(error.to_string()))?;
        let unauthenticated = UnauthenticatedConnection { connection };
        let authenticated =
            unauthenticated.authenticate(self.trust.as_ref(), ConnectionDirection::Outbound)?;
        if authenticated.device != peer {
            return Err(QuinnTransportError::KeyMismatch(peer));
        }
        let connection = authenticated.connection.clone();
        let (mut send, mut receive) = connection
            .open_bi()
            .await
            .map_err(|error| QuinnTransportError::Stream(error.to_string()))?;
        send.write_all(STREAM_PREFACE)
            .await
            .map_err(|error| QuinnTransportError::Stream(error.to_string()))?;
        read_preface(&mut receive).await?;
        self.register(authenticated, send, receive).await
    }

    async fn register(
        &self,
        authenticated: AuthenticatedConnection,
        send: SendStream,
        receive: RecvStream,
    ) -> Result<u64, QuinnTransportError> {
        if self.closed.load(Ordering::Acquire) {
            return Err(QuinnTransportError::Closed);
        }
        let generation = self.generation.fetch_add(1, Ordering::AcqRel) + 1;
        let peer = PeerId::from(authenticated.device.to_string());
        let (writer, frames) = mpsc::channel(self.config.writer_capacity);
        let previous = {
            let mut sessions = self
                .sessions
                .lock()
                .map_err(|_| QuinnTransportError::Closed)?;
            if let Some(current) = sessions.get(&peer) {
                let winner = choose_session(
                    self.identity.id(),
                    authenticated.device,
                    SessionCandidate {
                        direction: current.direction,
                        generation: current.generation,
                    },
                    SessionCandidate {
                        direction: authenticated.direction,
                        generation,
                    },
                );
                if winner.generation == current.generation && winner.direction == current.direction
                {
                    let current_generation = current.generation;
                    drop(sessions);
                    authenticated
                        .connection
                        .close(0_u32.into(), b"duplicate session lost");
                    return Ok(current_generation);
                }
            }
            sessions.insert(
                peer.clone(),
                Session {
                    generation,
                    direction: authenticated.direction,
                    connection: authenticated.connection.clone(),
                    writer,
                },
            )
        };
        if let Some(previous) = previous {
            previous.connection.close(0_u32.into(), b"session replaced");
            let _ = self
                .events_tx
                .send(NetworkEvent::PeerDisconnected(peer.clone()))
                .await;
        }
        self.events_tx
            .send(NetworkEvent::PeerConnected(peer.clone()))
            .await
            .map_err(|_| QuinnTransportError::Closed)?;
        let owner = self
            .self_weak
            .upgrade()
            .ok_or(QuinnTransportError::Closed)?;
        self.spawn_session_task(writer_loop(
            owner.clone(),
            peer.clone(),
            generation,
            authenticated.connection.clone(),
            send,
            frames,
        ));
        self.spawn_session_task(reader_loop(
            owner,
            peer,
            generation,
            authenticated.connection,
            receive,
        ));
        Ok(generation)
    }

    fn spawn_session_task(&self, future: impl Future<Output = ()> + Send + 'static) {
        self.track_task(tokio::spawn(future));
    }

    fn track_task(&self, task: JoinHandle<()>) {
        let mut tasks = self.tasks.lock().expect("task lock poisoned");
        tasks.retain(|existing| !existing.is_finished());
        tasks.push(task);
    }

    fn active_generation(&self, peer: &PeerId, generation: u64) -> bool {
        self.sessions.lock().is_ok_and(|sessions| {
            sessions
                .get(peer)
                .is_some_and(|session| session.generation == generation)
        })
    }

    async fn finish_generation(&self, peer: &PeerId, generation: u64) {
        let removed = self.sessions.lock().ok().and_then(|mut sessions| {
            if sessions
                .get(peer)
                .is_some_and(|session| session.generation == generation)
            {
                sessions.remove(peer)
            } else {
                None
            }
        });
        if removed.is_some() && !self.closed.load(Ordering::Acquire) {
            let _ = self
                .events_tx
                .send(NetworkEvent::PeerDisconnected(peer.clone()))
                .await;
        }
    }
}

use std::future::Future;

pub(crate) fn peer_certificate(
    connection: &Connection,
) -> Result<CertificateDer<'static>, QuinnTransportError> {
    let identity = connection
        .peer_identity()
        .ok_or(QuinnTransportError::MalformedCertificate)?;
    let chain = identity
        .downcast::<Vec<CertificateDer<'static>>>()
        .map_err(|_| QuinnTransportError::MalformedCertificate)?;
    if chain.len() != 1 {
        return Err(QuinnTransportError::MalformedCertificate);
    }
    Ok(chain[0].clone())
}

async fn read_preface(receive: &mut RecvStream) -> Result<(), QuinnTransportError> {
    let mut preface = [0_u8; STREAM_PREFACE.len()];
    receive
        .read_exact(&mut preface)
        .await
        .map_err(|error| QuinnTransportError::Stream(error.to_string()))?;
    if preface != STREAM_PREFACE {
        return Err(QuinnTransportError::Protocol("unsupported stream preface"));
    }
    Ok(())
}

async fn read_frame(receive: &mut RecvStream) -> Result<Option<Bytes>, QuinnTransportError> {
    read_frame_from(receive).await
}

async fn read_frame_from<R: AsyncRead + Unpin>(
    receive: &mut R,
) -> Result<Option<Bytes>, QuinnTransportError> {
    let mut prefix = [0_u8; FRAME_PREFIX_LEN];
    let mut prefix_read = 0;
    while prefix_read < prefix.len() {
        let count = receive
            .read(&mut prefix[prefix_read..])
            .await
            .map_err(|error| QuinnTransportError::Stream(error.to_string()))?;
        if count == 0 {
            return if prefix_read == 0 {
                Ok(None)
            } else {
                Err(QuinnTransportError::Protocol("truncated Repo frame prefix"))
            };
        }
        prefix_read += count;
    }
    let body_len = u32::from_be_bytes(prefix) as usize;
    if !(FRAME_BODY_HEADER_LEN..=MAX_BODY_LEN).contains(&body_len) {
        return Err(QuinnTransportError::Protocol("invalid Repo frame length"));
    }
    let mut frame = vec![0_u8; FRAME_PREFIX_LEN + body_len];
    frame[..FRAME_PREFIX_LEN].copy_from_slice(&prefix);
    receive
        .read_exact(&mut frame[FRAME_PREFIX_LEN..])
        .await
        .map_err(|error| QuinnTransportError::Stream(error.to_string()))?;
    if &frame[FRAME_PREFIX_LEN..FRAME_PREFIX_LEN + 4] != FRAME_MAGIC {
        return Err(QuinnTransportError::Protocol("invalid Repo frame magic"));
    }
    Ok(Some(Bytes::from(frame)))
}

async fn reader_loop(
    owner: Arc<QuinnTransport>,
    peer: PeerId,
    generation: u64,
    connection: Connection,
    mut receive: RecvStream,
) {
    loop {
        match read_frame(&mut receive).await {
            Ok(Some(bytes)) if owner.active_generation(&peer, generation) => {
                if owner
                    .events_tx
                    .send(NetworkEvent::Message {
                        peer: peer.clone(),
                        bytes,
                    })
                    .await
                    .is_err()
                {
                    break;
                }
            }
            Ok(Some(_)) => break,
            Ok(None) => break,
            Err(_) => {
                connection.close(2_u32.into(), b"invalid Repo frame");
                break;
            }
        }
    }
    owner.finish_generation(&peer, generation).await;
}

async fn writer_loop(
    owner: Arc<QuinnTransport>,
    peer: PeerId,
    generation: u64,
    connection: Connection,
    mut send: SendStream,
    mut frames: mpsc::Receiver<Bytes>,
) {
    while let Some(frame) = frames.recv().await {
        if !owner.active_generation(&peer, generation) {
            break;
        }
        let body_len = frame
            .get(..4)
            .and_then(|prefix| <[u8; 4]>::try_from(prefix).ok())
            .map(u32::from_be_bytes)
            .map(|value| value as usize);
        if body_len.is_none_or(|body_len| {
            !(FRAME_BODY_HEADER_LEN..=MAX_BODY_LEN).contains(&body_len)
                || frame.len() != FRAME_PREFIX_LEN + body_len
        }) || send.write_all(&frame).await.is_err()
        {
            connection.close(2_u32.into(), b"Repo writer failure");
            break;
        }
    }
    let _ = send.finish();
    owner.finish_generation(&peer, generation).await;
}

#[async_trait]
impl NetworkTransport for QuinnTransport {
    fn take_events(&self) -> Result<mpsc::Receiver<NetworkEvent>, NetworkError> {
        self.events_rx
            .lock()
            .map_err(|_| NetworkError::Closed)?
            .take()
            .ok_or(NetworkError::EventsAlreadyTaken)
    }

    async fn send(&self, peer: &PeerId, frame: Bytes) -> Result<(), NetworkError> {
        let writer = self
            .sessions
            .lock()
            .map_err(|_| NetworkError::Closed)?
            .get(peer)
            .map(|session| session.writer.clone())
            .ok_or_else(|| NetworkError::Transport {
                peer: peer.clone(),
                message: "peer is not connected".into(),
            })?;
        writer
            .send(frame)
            .await
            .map_err(|_| NetworkError::Transport {
                peer: peer.clone(),
                message: "peer writer is closed".into(),
            })
    }

    async fn close_peer(&self, peer: &PeerId) -> Result<(), NetworkError> {
        let removed = self
            .sessions
            .lock()
            .map_err(|_| NetworkError::Closed)?
            .remove(peer);
        if let Some(session) = removed {
            session.connection.close(0_u32.into(), b"peer closed");
            let _ = self
                .events_tx
                .send(NetworkEvent::PeerDisconnected(peer.clone()))
                .await;
        }
        Ok(())
    }

    async fn close(&self) -> Result<(), NetworkError> {
        if self.closed.swap(true, Ordering::AcqRel) {
            return Ok(());
        }
        self.endpoint.close(0_u32.into(), b"application shutdown");
        let sessions = self
            .sessions
            .lock()
            .map_err(|_| NetworkError::Closed)?
            .drain()
            .collect::<Vec<_>>();
        for (_peer, session) in sessions {
            session
                .connection
                .close(0_u32.into(), b"application shutdown");
        }
        self.endpoint.wait_idle().await;
        let tasks = self
            .tasks
            .lock()
            .map_err(|_| NetworkError::Closed)?
            .drain(..)
            .collect::<Vec<_>>();
        for task in tasks {
            task.abort();
            let _ = task.await;
        }
        Ok(())
    }
}

#[async_trait]
impl PeerConnector for QuinnTransport {
    async fn connect(
        &self,
        peer: DeviceId,
        endpoint: NetworkEndpoint,
    ) -> Result<u64, ConnectionFailure> {
        self.dial(peer, endpoint.address)
            .await
            .map_err(|error| match error {
                QuinnTransportError::UnknownPeer(_)
                | QuinnTransportError::RevokedPeer(_)
                | QuinnTransportError::KeyMismatch(_) => {
                    ConnectionFailure::Trust(error.to_string())
                }
                QuinnTransportError::MalformedCertificate
                | QuinnTransportError::WrongPublicKeyAlgorithm
                | QuinnTransportError::InvalidCertificateSignature
                | QuinnTransportError::Configuration(_) => {
                    ConnectionFailure::Tls(error.to_string())
                }
                QuinnTransportError::Stream(_) | QuinnTransportError::Protocol(_) => {
                    ConnectionFailure::Stream(error.to_string())
                }
                QuinnTransportError::Connection(_) => ConnectionFailure::Route(error.to_string()),
                QuinnTransportError::Closed => ConnectionFailure::Transport(error.to_string()),
            })
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::identity::InMemorySecureKeyStore;
    use std::time::Duration;

    async fn identity(seed: u8) -> Arc<DeviceIdentity> {
        Arc::new(
            DeviceIdentity::load_or_create(&InMemorySecureKeyStore::seeded([seed; 32]))
                .await
                .unwrap(),
        )
    }

    fn trusted(identity: &DeviceIdentity, state: TrustState) -> PeerTrustRecord {
        PeerTrustRecord {
            device_id: identity.id(),
            public_key: identity.public_key(),
            state,
            updated_at_ms: 1,
            last_seen_ms: None,
        }
    }

    fn frame(body: &[u8]) -> Bytes {
        let body_len = FRAME_BODY_HEADER_LEN + body.len();
        let mut frame = Vec::from((body_len as u32).to_be_bytes());
        frame.extend_from_slice(FRAME_MAGIC);
        frame.extend_from_slice(&[1, 1, 0, 0]);
        frame.extend_from_slice(body);
        Bytes::from(frame)
    }

    async fn event(events: &mut mpsc::Receiver<NetworkEvent>) -> NetworkEvent {
        tokio::time::timeout(Duration::from_secs(3), events.recv())
            .await
            .unwrap()
            .unwrap()
    }

    #[test]
    fn certificate_is_bound_to_permanent_identity_and_malformed_der_is_rejected() {
        let runtime = tokio::runtime::Runtime::new().unwrap();
        runtime.block_on(async {
            let identity = identity(1).await;
            let certificate = TlsIdentity::generate(&identity).unwrap();
            assert_eq!(
                extract_public_key(&certificate.certificate).unwrap(),
                identity.public_key()
            );
            assert!(extract_public_key(&CertificateDer::from(vec![1, 2, 3])).is_err());
        });
    }

    #[tokio::test]
    async fn trusted_loopback_uses_one_stream_and_preserves_complete_frames() {
        let identity_a = identity(2).await;
        let identity_b = identity(3).await;
        let trust_a = Arc::new(MemoryTrustResolver::default());
        let trust_b = Arc::new(MemoryTrustResolver::default());
        trust_a.set(trusted(&identity_b, TrustState::Trusted));
        trust_b.set(trusted(&identity_a, TrustState::Trusted));
        let a = QuinnTransport::bind(
            ([127, 0, 0, 1], 0).into(),
            identity_a.clone(),
            trust_a,
            QuinnTransportConfig::default(),
        )
        .unwrap();
        let b = QuinnTransport::bind(
            ([127, 0, 0, 1], 0).into(),
            identity_b.clone(),
            trust_b,
            QuinnTransportConfig::default(),
        )
        .unwrap();
        let mut events_a = NetworkTransport::take_events(a.as_ref()).unwrap();
        let mut events_b = NetworkTransport::take_events(b.as_ref()).unwrap();
        a.dial(identity_b.id(), b.local_addr().unwrap())
            .await
            .unwrap();
        assert_eq!(
            event(&mut events_a).await,
            NetworkEvent::PeerConnected(PeerId::from(identity_b.id().to_string()))
        );
        assert_eq!(
            event(&mut events_b).await,
            NetworkEvent::PeerConnected(PeerId::from(identity_a.id().to_string()))
        );
        a.dial(identity_b.id(), b.local_addr().unwrap())
            .await
            .unwrap();
        for events in [&mut events_a, &mut events_b] {
            assert!(matches!(
                event(events).await,
                NetworkEvent::PeerDisconnected(_)
            ));
            assert!(matches!(
                event(events).await,
                NetworkEvent::PeerConnected(_)
            ));
        }
        let after_replacement = frame(b"replacement");
        NetworkTransport::send(
            a.as_ref(),
            &PeerId::from(identity_b.id().to_string()),
            after_replacement.clone(),
        )
        .await
        .unwrap();
        assert_eq!(
            event(&mut events_b).await,
            NetworkEvent::Message {
                peer: PeerId::from(identity_a.id().to_string()),
                bytes: after_replacement
            }
        );
        let expected = frame(b"first");
        NetworkTransport::send(
            a.as_ref(),
            &PeerId::from(identity_b.id().to_string()),
            expected.clone(),
        )
        .await
        .unwrap();
        assert_eq!(
            event(&mut events_b).await,
            NetworkEvent::Message {
                peer: PeerId::from(identity_a.id().to_string()),
                bytes: expected
            }
        );
        NetworkTransport::close(a.as_ref()).await.unwrap();
        NetworkTransport::close(b.as_ref()).await.unwrap();
    }

    async fn assert_rejected(state: TrustState) {
        let identity_a = identity(4).await;
        let identity_b = identity(5).await;
        let trust_a = Arc::new(MemoryTrustResolver::default());
        let trust_b = Arc::new(MemoryTrustResolver::default());
        trust_a.set(trusted(&identity_b, TrustState::Trusted));
        if state == TrustState::Revoked {
            trust_b.set(trusted(&identity_a, state));
        }
        let a = QuinnTransport::bind(
            ([127, 0, 0, 1], 0).into(),
            identity_a.clone(),
            trust_a,
            QuinnTransportConfig::default(),
        )
        .unwrap();
        let b = QuinnTransport::bind(
            ([127, 0, 0, 1], 0).into(),
            identity_b.clone(),
            trust_b,
            QuinnTransportConfig::default(),
        )
        .unwrap();
        let mut events_b = NetworkTransport::take_events(b.as_ref()).unwrap();
        assert!(
            a.dial(identity_b.id(), b.local_addr().unwrap())
                .await
                .is_err()
        );
        assert!(
            tokio::time::timeout(Duration::from_millis(100), events_b.recv())
                .await
                .is_err()
        );
        NetworkTransport::close(a.as_ref()).await.unwrap();
        NetworkTransport::close(b.as_ref()).await.unwrap();
    }

    #[tokio::test]
    async fn unknown_and_revoked_peers_never_emit_repo_admission_events() {
        assert_rejected(TrustState::Trusted).await;
        assert_rejected(TrustState::Revoked).await;
    }

    #[tokio::test]
    async fn simultaneous_sessions_select_the_same_device_id_preferred_connection() {
        let identity_a = identity(6).await;
        let identity_b = identity(7).await;
        let trust_a = Arc::new(MemoryTrustResolver::default());
        let trust_b = Arc::new(MemoryTrustResolver::default());
        trust_a.set(trusted(&identity_b, TrustState::Trusted));
        trust_b.set(trusted(&identity_a, TrustState::Trusted));
        let a = QuinnTransport::bind(
            ([127, 0, 0, 1], 0).into(),
            identity_a.clone(),
            trust_a,
            QuinnTransportConfig::default(),
        )
        .unwrap();
        let b = QuinnTransport::bind(
            ([127, 0, 0, 1], 0).into(),
            identity_b.clone(),
            trust_b,
            QuinnTransportConfig::default(),
        )
        .unwrap();
        let (dial_a, dial_b) = tokio::join!(
            a.dial(identity_b.id(), b.local_addr().unwrap()),
            b.dial(identity_a.id(), a.local_addr().unwrap()),
        );
        dial_a.unwrap();
        dial_b.unwrap();
        tokio::time::sleep(Duration::from_millis(50)).await;
        let peer_a = PeerId::from(identity_b.id().to_string());
        let peer_b = PeerId::from(identity_a.id().to_string());
        let direction_a = a.sessions.lock().unwrap().get(&peer_a).unwrap().direction;
        let direction_b = b.sessions.lock().unwrap().get(&peer_b).unwrap().direction;
        let expected_a = if identity_a.id() < identity_b.id() {
            ConnectionDirection::Outbound
        } else {
            ConnectionDirection::Inbound
        };
        assert_eq!(direction_a, expected_a);
        assert_eq!(
            direction_b,
            if expected_a == ConnectionDirection::Outbound {
                ConnectionDirection::Inbound
            } else {
                ConnectionDirection::Outbound
            }
        );
        NetworkTransport::close(a.as_ref()).await.unwrap();
        NetworkTransport::close(b.as_ref()).await.unwrap();
    }

    #[test]
    fn oversized_prefix_is_rejected_before_body_allocation() {
        let header = Vec::from(((MAX_BODY_LEN as u32) + 1).to_be_bytes());
        let advertised = u32::from_be_bytes(header[..4].try_into().unwrap()) as usize;
        assert!(advertised > MAX_BODY_LEN);
        assert_eq!(header.len(), FRAME_PREFIX_LEN);
    }

    #[tokio::test]
    async fn fragmented_and_coalesced_frames_are_read_exactly_once_in_order() {
        use tokio::io::AsyncWriteExt;

        let first = frame(b"fragmented");
        let second = frame(b"coalesced");
        let combined = [first.as_ref(), second.as_ref()].concat();
        let (mut writer, mut reader) = tokio::io::duplex(combined.len() + 1);
        let write = tokio::spawn(async move {
            for chunk in combined.chunks(3) {
                writer.write_all(chunk).await.unwrap();
                tokio::task::yield_now().await;
            }
            writer.shutdown().await.unwrap();
        });
        assert_eq!(read_frame_from(&mut reader).await.unwrap(), Some(first));
        assert_eq!(read_frame_from(&mut reader).await.unwrap(), Some(second));
        assert_eq!(read_frame_from(&mut reader).await.unwrap(), None);
        write.await.unwrap();
    }

    #[tokio::test]
    async fn oversize_prefix_fails_without_waiting_for_or_allocating_a_body() {
        use tokio::io::AsyncWriteExt;

        let (mut writer, mut reader) = tokio::io::duplex(4);
        writer
            .write_all(&((MAX_BODY_LEN as u32) + 1).to_be_bytes())
            .await
            .unwrap();
        assert!(matches!(
            read_frame_from(&mut reader).await,
            Err(QuinnTransportError::Protocol("invalid Repo frame length"))
        ));
    }

    #[tokio::test]
    async fn bounded_writer_queue_applies_backpressure_until_capacity_returns() {
        let (writer, mut receiver) = mpsc::channel(1);
        writer.send(frame(b"one")).await.unwrap();
        let blocked = writer.send(frame(b"two"));
        tokio::pin!(blocked);
        assert!(
            tokio::time::timeout(Duration::from_millis(20), &mut blocked)
                .await
                .is_err()
        );
        receiver.recv().await.unwrap();
        blocked.await.unwrap();
    }
}
