# app-settings Specification

## Purpose

Gives every platform a Settings destination and shows in it only the sections the running platform can use, decided by platform capability rather than window width.

## Requirements

### Requirement: Settings destination in both layouts
Settings SHALL be a top-level destination on every platform and at every width. At 720px and wider the navigation sidebar SHALL list Collections, Devices and Settings in that order, Settings using the settings (gear) icon and the same selected styling as the other sidebar rows (mock 8a). Below 720px the bottom navigation SHALL show Collections, Devices and Settings. The selected destination SHALL be kept when the window crosses 720px in either direction; in particular Settings stays selected and shown. Any action that opens Settings (for example "Settings" in a voice error panel) SHALL select the Settings destination in either layout.

#### Scenario: Sidebar lists Settings under Devices
- **WHEN** the app is shown on a 1240px-wide screen
- **THEN** the sidebar shows Collections, Devices and Settings in that order, and tapping Settings shows the Settings page with the Settings row selected

#### Scenario: Phone bottom bar
- **WHEN** the app is shown on a 390px-wide screen
- **THEN** the bottom navigation shows Collections, Devices and Settings

#### Scenario: Settings survives widening
- **WHEN** Settings is selected on a 500px-wide window and the window is widened to 1000px
- **THEN** the Settings page is still shown and the sidebar's Settings row is selected

#### Scenario: Settings survives narrowing
- **WHEN** Settings is selected on a 1000px-wide window and the window is narrowed to 500px
- **THEN** the Settings page is still shown and the bottom navigation's Settings destination is selected

### Requirement: Settings sections follow platform capabilities
The app SHALL decide which Settings sections appear from the running platform's capabilities, never from the window width. The capabilities SHALL be replaceable as a whole so tests can present the app as Android or as desktop. Sections SHALL appear in this order, each with its section label:
- Voice input: shown only when the platform supports on-device voice (Android) and a voice engine is available to the build. Its content is defined by the voice-record-fill capability.
- Microphone: shown only on Android and only when Voice input is shown. It holds "Microphone access" with the permission state ("Allowed", "Not allowed yet" with "Fi asks the first time you use voice.", "Off" with "Turn it on in Android settings to fill by voice."), and an "Android settings" button that opens this app's Android settings page. The permission state SHALL be read again when the app returns to the foreground.
- About: shown on every platform.

No text mentioning Android, and no control that opens Android settings, SHALL appear on a platform other than Android. On a platform other than Android the page header SHALL read "Settings" with the line "Preferences for this computer." under it; on Android the header SHALL read "Settings" alone.

#### Scenario: Desktop shows only About
- **WHEN** the app runs with desktop capabilities, even with a voice engine available, and the user opens Settings on a 1240px-wide screen
- **THEN** Settings shows "Preferences for this computer." and the About section, and shows no Voice input section, no Microphone section and no "Android settings" button

#### Scenario: Desktop capabilities at phone width
- **WHEN** the app runs with desktop capabilities and a voice engine available, and the window is 390px wide
- **THEN** Settings still shows no Voice input and no Microphone section

#### Scenario: Android with voice available
- **WHEN** the app runs with Android capabilities and a voice engine is available
- **THEN** Settings shows Voice input, Microphone and About in that order

#### Scenario: Android without a voice engine
- **WHEN** the app runs with Android capabilities and no voice engine is available to the build
- **THEN** Settings shows only About

#### Scenario: Permission changed in Android settings
- **WHEN** the Microphone section shows "Off", the user taps "Android settings", allows the microphone there and returns to the app
- **THEN** the Microphone section shows "Allowed"

### Requirement: About section
The About section SHALL be shown on every platform as one card with these rows in order:
- "Version" with the build label, shown only once the build identity is known.
- "Network" with the low-emphasis line "Local network only · UDP 47380–47389 · mDNS 5353", stating that sync and pairing use only the local network, the UDP port range 47380–47389, and mDNS on port 5353. The line SHALL use the muted text colour and a smaller size than the row label.

The About section SHALL render even while the build identity is pending or after it failed; the Version row is then absent and the Network row is still shown.

#### Scenario: About on desktop
- **WHEN** the app runs with desktop capabilities, the build identity is `0.1.21`, `a1b2c3d`, not dirty, and the user opens Settings
- **THEN** About shows "Version" with `fi 0.1.21 · a1b2c3d` and "Network" with "Local network only · UDP 47380–47389 · mDNS 5353"

#### Scenario: Build identity unavailable
- **WHEN** the build-identity query fails and the user opens Settings
- **THEN** About shows the Network row and no Version row
