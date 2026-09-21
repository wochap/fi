## Purpose

Define secure provisioning of an existing repository root and discovery state to a fresh installation after confirmed pairing.

## Requirements

### Requirement: Existing-root provisioning policy
The primary join flow SHALL require one ready device and one `NeedsDecision` installation; two ready devices SHALL pair only when their root IDs match, and devices with different established roots MUST NOT merge or replace either root.

#### Scenario: Ready device pairs with fresh installation
- **WHEN** bilateral SAS confirmation succeeds
- **THEN** the ready device provisions its existing root ID and the fresh installation accepts that exact root

#### Scenario: Established roots differ
- **WHEN** two ready devices reveal different root IDs inside the encrypted pairing channel
- **THEN** pairing fails before trust or provisioning commit and neither root changes

#### Scenario: Both devices are rootless
- **WHEN** two `NeedsDecision` installations attempt to pair
- **THEN** pairing reports that one device must first create a dataset and establishes no trust

### Requirement: Provisioning confidentiality and integrity
The root ID, discovery-group secret, epoch, and peer control data SHALL be sent only after bilateral confirmation over the current TLS channel and SHALL be authenticated with a transcript-derived provisioning key.

#### Scenario: Provisioning is modified
- **WHEN** any protected provisioning field is changed, replayed for another transcript, or fails its authentication tag
- **THEN** the receiver rejects it and does not join a root or install the discovery secret

### Requirement: Durable join ordering
A joining device SHALL journal the received provisioning state, durably install the discovery secret and trusted peer metadata, call `Repo::join_existing` for the received root, and remain write-gated until remote root history and its SQLite projection are ready.

#### Scenario: Join synchronizes complete data
- **WHEN** the fresh device provisions from a ready peer containing categories and transactions
- **THEN** its Repo reaches Ready for the same root and its rebuilt read model returns the complete synchronized data before finance commands are enabled

#### Scenario: Join is interrupted
- **WHEN** the process or network stops after the root decision is durably journaled but before root history is complete
- **THEN** restart preserves the exact joining root, remains write-gated, and can resume synchronization without a local root commit

### Requirement: Fresh normal session after pairing
Completed pairing SHALL close its pairing protocol connection and establish Repo synchronization only through a new normal connection that verifies the newly pinned keys and trust records.

#### Scenario: Pairing commit succeeds
- **WHEN** both sides finish durable pairing commit
- **THEN** no pairing stream is reused for Repo frames and a subsequent `myapp-sync/1` session passes the normal trust gate

### Requirement: A root is not created while a pairing window is open
A device in the needs-decision state SHALL NOT create a local root while a pairing window is open.
Because the root state advertised in a pairing handshake is captured when the window opens, creating a
root mid-window would cause a peer to provision against a root state that no longer holds and would
leave the two devices holding different established roots. Any active pairing window SHALL be closed
before a root creation is issued.

#### Scenario: Creation is requested during an open pairing window
- **WHEN** a needs-decision device has an open pairing window and the user requests creation of a local
  dataset
- **THEN** the pairing window is closed before the root is created, and no handshake in progress
  advertises the superseded root state

#### Scenario: Provisioning is rejected against a superseded root state
- **WHEN** a device that has created a root receives provisioning data from a peer that elected itself
  provisioner from a stale needs-decision advertisement
- **THEN** the provisioning is rejected, no partial trust or partial root adoption is persisted, and
  the device retains the root it created
