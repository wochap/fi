# app-settings Specification

## Purpose

Gives every platform a Settings destination and shows in it only the sections the running platform can use, decided by platform capability rather than window width.

## Requirements

### Requirement: Settings destination in both layouts
Settings SHALL be a top-level destination on every platform and at every width. At 720px and wider the navigation sidebar SHALL list Collections, Devices and Settings in that order, Settings using the settings (gear) icon and the same selected styling as the other sidebar rows (mock settings). Below 720px the bottom navigation SHALL show Collections, Devices and Settings. The selected destination SHALL be kept when the window crosses 720px in either direction; in particular Settings stays selected and shown. Any action that opens Settings (for example "Settings" in a voice error panel) SHALL select the Settings destination in either layout.

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
- Language: shown on every platform. Its content is defined by the Language section requirement.
- Voice input: shown only when the platform supports on-device voice (Android) and a voice engine is available to the build. Its content is defined by the voice-record-fill capability.
- Microphone: shown only on Android and only when Voice input is shown. It holds "Microphone access" with the permission state ("Allowed", "Not allowed yet" with "Fi asks the first time you use voice.", "Off" with "Turn it on in Android settings to fill by voice."), and an "Android settings" button that opens this app's Android settings page. The permission state SHALL be read again when the app returns to the foreground.
- About: shown on every platform.

No text mentioning Android, and no control that opens Android settings, SHALL appear on a platform other than Android. On a platform other than Android the page header SHALL read "Settings" with the line "Preferences for this computer." under it; on Android the header SHALL read "Settings" alone.

#### Scenario: Desktop shows Language and About
- **WHEN** the app runs with desktop capabilities, even with a voice engine available, and the user opens Settings on a 1240px-wide screen
- **THEN** Settings shows "Preferences for this computer.", the Language section and then the About section, and shows no Voice input section, no Microphone section and no "Android settings" button

#### Scenario: Desktop capabilities at phone width
- **WHEN** the app runs with desktop capabilities and a voice engine available, and the window is 390px wide
- **THEN** Settings still shows no Voice input and no Microphone section

#### Scenario: Android with voice available
- **WHEN** the app runs with Android capabilities and a voice engine is available
- **THEN** Settings shows Language, Voice input, Microphone and About in that order

#### Scenario: Android without a voice engine
- **WHEN** the app runs with Android capabilities and no voice engine is available to the build
- **THEN** Settings shows only Language and About

#### Scenario: Permission changed in Android settings
- **WHEN** the Microphone section shows "Off", the user taps "Android settings", allows the microphone there and returns to the app
- **THEN** the Microphone section shows "Allowed"

### Requirement: Language section
The Language section SHALL offer three choices: System default, English and Español. "English" and "Español" SHALL always be written in their own language. The System default choice SHALL name the language the system currently resolves to, in that language's own name. The current preference SHALL be marked. Picking a choice SHALL apply it at once and store it on the device.
- On a platform other than Android (mock settings), the section SHALL be one card with the row "App language", the line "Menus, labels and dates. Changes apply right away." under it, and a dropdown showing the current choice. The System default entry SHALL read "System default (<language>)", for example "System default (English)".
- On Android (mocks settings, shared-spanish), the section SHALL be one card holding a radio list with the rows "System default" (with the line "<language> — same as your phone", for example "English — same as your phone"), "English" and "Español".

Where the Voice input section is shown, the Language section SHALL also tell the user that voice input follows the app language, under the language choices (mocks settings, settings-language):
- When the voice language's model set is ready: the line "Voice input follows the app language · <language> models ready", for example "Voice input follows the app language · English models ready".
- When the understanding model is on the phone, the voice language's speech model is not verified, no download is running, and the offer was not dismissed for this language: an inline offer with the title "Download <language> speech model · <size>" (for example "Download Spanish speech model · 148 MB", "Descargar modelo de voz en español · 148 MB"), the line "Voice input follows the app language. Understanding (<size>) is already on this phone.", and "Not now" / "Download". Download SHALL start the download of the voice language's set, which then fetches only the speech model. Not now SHALL keep the chosen language, hide the offer for that language until the app language changes again or Settings is opened again, and leave voice fill off until the model is downloaded.
- Otherwise: the line "Voice input follows the app language".

Sizes SHALL come from the model manifest. Where the Voice input section is not shown, no voice text SHALL appear in the Language section.

#### Scenario: Desktop dropdown
- **WHEN** the app runs with desktop capabilities on an English system and the user opens Settings
- **THEN** the Language section shows "App language", "Menus, labels and dates. Changes apply right away." and a dropdown reading "System default (English)", whose entries are "System default (English)", "English" and "Español", and no voice line

#### Scenario: Android radio list
- **WHEN** the app runs with Android capabilities on an English system, a voice engine is available, the English set is ready, and the user opens Settings
- **THEN** the Language section shows the rows "System default" with "English — same as your phone", "English" and "Español", System default is selected, and the line "Voice input follows the app language · English models ready" is shown

#### Scenario: Picking Español on Android
- **WHEN** the user taps "Español" in the Android Language section
- **THEN** the row "Español" is selected, the page title reads "Ajustes", and the System default row reads "Predeterminado del sistema" with "English — igual que tu teléfono"

#### Scenario: Spanish speech model offer
- **WHEN** the English set is ready, a voice engine is available on Android, and the user picks Español
- **THEN** under the language list the offer "Descargar modelo de voz en español · 148 MB" appears with "La entrada de voz sigue el idioma de la app. El modelo de comprensión (1,29 GB) ya está en este teléfono.", "Ahora no" and "Descargar"

#### Scenario: Download from the offer
- **WHEN** the Spanish speech model offer is shown and the user taps "Descargar"
- **THEN** the download of `ggml-base.bin` starts, the offer is replaced by the line "La entrada de voz sigue el idioma de la app", and the voice models card shows the download progress

#### Scenario: Not now keeps the language
- **WHEN** the Spanish speech model offer is shown and the user taps "Ahora no"
- **THEN** the offer closes, the interface stays in Spanish, and the mic in New record leads to the download offer

### Requirement: About section
The About section SHALL be shown on every platform as one card with these rows in order:
- "Version" with the build label, shown only once the build identity is known.
- "This device" with every address at which a paired device on the same local network or tailnet can reach this one, as exposed by the core (LAN addresses first, then tailnet addresses), one per line as `ip:port` using the bound sync port (for example `192.168.0.165:47380`), in a monospace presentation. Each address SHALL have a copy action that places exactly that `ip:port` on the clipboard and confirms the copy with "Address copied". While no address is available (networking not running, or neither a local-network nor a tailnet connection) the row SHALL read "Not on a local network or tailnet" instead. The addresses SHALL be read again when Settings is opened and when the app returns to the foreground, so a device that changed networks shows its new address.
- "Network" with the low-emphasis line "Local network and tailnet · UDP 47380–47389 · mDNS 5353", stating that sync uses the local network and the tailnet, the UDP port range 47380–47389, and mDNS on port 5353. The line SHALL use the muted text colour and a smaller size than the row label.

The About section SHALL render even while the build identity is pending or after it failed; the Version row is then absent and the This device and Network rows are still shown.

#### Scenario: About on desktop
- **WHEN** the app runs with desktop capabilities, the build identity is `0.1.21`, `a1b2c3d`, not dirty, the device's LAN address is `192.168.0.165` with sync bound to `47380`, and the user opens Settings
- **THEN** About shows "Version" with `fi 0.1.21 · a1b2c3d`, then "This device" with `192.168.0.165:47380`, then "Network" with "Local network and tailnet · UDP 47380–47389 · mDNS 5353"

#### Scenario: Copy this device's address
- **WHEN** the user presses the copy action beside `192.168.0.165:47380`
- **THEN** the clipboard holds `192.168.0.165:47380` and "Address copied" is shown

#### Scenario: Two addresses
- **WHEN** the device is connected to Ethernet at `192.168.0.10` and Wi-Fi at `192.168.0.165` with sync on `47380`
- **THEN** "This device" lists `192.168.0.10:47380` and `192.168.0.165:47380`, each with its own copy action

#### Scenario: LAN and tailnet addresses
- **WHEN** the device has Wi-Fi at `192.168.0.165` and the tailnet address `100.71.3.9` with sync on `47380`
- **THEN** "This device" lists `192.168.0.165:47380` then `100.71.3.9:47380`, each with its own copy action

#### Scenario: No local network
- **WHEN** networking is not running or the device has neither a local-network nor a tailnet address
- **THEN** "This device" reads "Not on a local network or tailnet" and offers no copy action

#### Scenario: Address changes after roaming
- **WHEN** the device moves to another Wi-Fi network while the app is in the background and the user returns to the app and opens Settings
- **THEN** "This device" shows the address on the new network

#### Scenario: Build identity unavailable
- **WHEN** the build-identity query fails and the user opens Settings
- **THEN** About shows the This device and Network rows and no Version row
