# Network security

fi is a personal LAN sync app. This document lists every socket it opens, what
each one exposes before authentication, the threat model, and how to firewall
the ports to the local network.

## Sockets and ports

| Socket | Transport | Bind address | Port | Lifetime | Protocol id | Authentication | Limits |
| --- | --- | --- | --- | --- | --- | --- | --- |
| Sync | QUIC over UDP | `0.0.0.0` (IPv4) | lowest free port in `47380-47389` | while networking runs | ALPN `fi-sync/1` | mutual TLS 1.3, both certificates pinned to trusted device keys | at most 8 connections; non-LAN sources dropped |
| Pairing | QUIC over UDP | `0.0.0.0` (IPv4) | a free port in `47380-47389` other than the sync port | only while a pairing window is open (at most the requested duration) | ALPN `fi-pair/1` | TLS 1.3 with structurally valid identity-key certificates, then a SAS both users confirm | one session at a time; non-LAN sources dropped |
| mDNS | UDP multicast | `224.0.0.251:5353` | `5353` | while discovery runs | normal service `_fi-<10 base32>` derived from the group secret; pairing service `_fi-gremyncn3q` only during a window | none (records carry no secrets) | IPv4 non-loopback interfaces only on a LAN bind |

The Android client uses the same sockets.

A sync or pairing endpoint drops an inbound connection whose source address is
not a LAN peer address before the TLS handshake starts, and sends no reply. On
an IPv4 bind a LAN peer address is a private (RFC 1918) or link-local IPv4
address. Loopback is not a LAN peer address on a `0.0.0.0` bind, so a second
instance on the same host is reached through the LAN address.

If the range has no free port, the sync bind defers networking at open, and a
pairing window fails to start with the ports-exhausted error. fi never falls
back to a random port.

## Exposed before authentication

- **Sync.** A LAN host that completes the TLS handshake sees the server
  certificate. The certificate contains the Ed25519 public key, so the host
  learns the DeviceId and that fi runs on this port. Nothing else is sent before
  the peer's own certificate is checked against the trusted keys.
- **Pairing.** During a window, a LAN host sees the certificate. After it sends
  a hello, it also receives the device's friendly name and root state in the
  responder hello. The SAS prevents trust unless both users confirm matching
  codes. A failed inbound handshake (bad hello, key mismatch, incompatible
  roots, or no hello within 10 seconds) closes only that connection; the window
  stays open.
- **mDNS.** Normal records carry only an opaque selector, a routing token, the
  epoch, the port, and LAN addresses. Pairing records carry a random instance
  id, the port, and the protocol version.

ALPN values travel in the QUIC Initial packet, which any on-path observer can
decrypt, so `fi-sync/1` and `fi-pair/1` are visible on the LAN.

## Threat model

In scope:

- Hosts on the same LAN: passive observers, active scanners, and malicious
  peers without a trusted key.
- Off-LAN hosts. Their connections are dropped before the handshake.

Out of scope:

- A compromised trusted device.
- Operating-system-level compromise of a device.
- Traffic analysis that shows two devices sync with each other.

Accepted risks:

- The DeviceId is visible to a LAN host through the sync server certificate.
- The friendly name is visible to a pairing peer before the SAS is confirmed.
- UDP source addresses can be spoofed. A spoofed LAN source can trigger a
  bounded handshake whose reply goes to the spoofed host; QUIC anti-amplification
  limits the reflected bytes, and an off-LAN sender cannot complete TLS.
- VPN and CGNAT peers (for example Tailscale `100.64.0.0/10`) are not LAN peer
  addresses and are dropped.

## IPv4 only

QUIC binds `0.0.0.0`. IPv6 is not used for QUIC or for mDNS on a LAN bind.

## Firewall

Allow fi's ports from your LAN subnet only. The examples use `192.168.0.0/24`;
replace it with your subnet. Android needs no rule.

- UDP `47380:47389`: QUIC sync and pairing.
- UDP `5353`: mDNS.

### NixOS

In `configuration.nix`:

```nix
networking.firewall.extraCommands = ''
  iptables -A nixos-fw -s 192.168.0.0/24 -p udp --dport 47380:47389 -j nixos-fw-accept
  iptables -A nixos-fw -s 192.168.0.0/24 -p udp --dport 5353 -j nixos-fw-accept
'';
networking.firewall.extraStopCommands = ''
  iptables -D nixos-fw -s 192.168.0.0/24 -p udp --dport 47380:47389 -j nixos-fw-accept || true
  iptables -D nixos-fw -s 192.168.0.0/24 -p udp --dport 5353 -j nixos-fw-accept || true
'';
```

Do not use `networking.firewall.allowedUDPPortRanges` for this range: it opens
the ports to every source.

### ufw

```sh
sudo ufw allow from 192.168.0.0/24 to any port 47380:47389 proto udp
sudo ufw allow from 192.168.0.0/24 to any port 5353 proto udp
```

### iptables

Rules added this way are lost on reboot.

```sh
sudo iptables -I INPUT -s 192.168.0.0/24 -p udp --dport 47380:47389 -j ACCEPT
sudo iptables -I INPUT -s 192.168.0.0/24 -p udp --dport 5353 -j ACCEPT
```

### OpenSnitch

The app's first packet to a new peer, including its reply to an inbound dial, is
a new outbound flow. OpenSnitch queues it for a prompt and, unanswered, denies
it after 30 s, which equals the pairing timeout. Add permanent rules instead:

- Allow process `fi`, protocol `udp`, destination port matching the regex
  `^4738[0-9]$`.
- Allow process `fi`, protocol `udp`, destination port `5353`, if mDNS is not
  already permitted.

### Reachability checks

From another LAN host, `ping` must succeed in both directions. On Android the
phone's default route must be Wi-Fi: `adb shell ip route get <desktop-ip>` must
name `wlan0`. If it names a cellular interface, turn mobile data off.
