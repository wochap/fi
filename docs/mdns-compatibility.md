# Dynamic private DNS-SD compatibility

The group selector uses `_fi-<10 base32 characters>._udp.local.`. Its service
label is 14 bytes, within Android `NsdServiceInfo` and RFC 6763's conventional
15-byte service-label limit. `mdns-sd` 0.21.2 validates this form and uses the
same multicast DNS packet format on Android and Linux.

The Linux adapter is exercised through the provider lifecycle and loopback
tests. Android packaging uses the same Rust adapter and requires multicast/Wi-Fi
permissions in the final Flutter UI change. If a device vendor rejects dynamic
service types, `DiscoveryProvider` remains the boundary for an exact
group-derived owner-query adapter; no identity, trust, or Repo code changes.
