# location-fields Specification

## Purpose

Defines the `Location` field type's coordinate capture, permission primer, OpenStreetMap tile rendering with persistent disk cache and mobile-data protection, interactive map picker, Photon place search and reverse-geocoding hints, coordinate and map-link parsing (including `maps.app.goo.gl` short-link redirect resolution), and view-mode external map handoff.

## Requirements

### Requirement: Location record form states
A `Location` field on the record form SHALL support nine states:
1. **Empty:** Shows two actions side by side: `Current location` (`ph-gps-fix`) and `Pick on map` (`ph-map-trifold`).
2. **Locating:** Replaces the empty buttons with a status box showing a spinning ring, `Finding you… ±<accuracy> m` in tabular monospace (counting down as better fixes arrive), and a `Cancel` action. It SHALL wait for horizontal accuracy `<= 25 m` or a `10 s` timeout, whichever comes first, then keep the best fix received.
3. **Has value · map preview on:** When the field's `show_map_preview` setting is on and tiles are available, shows a `132px`-tall mini map centered on the coordinates with a fixed center pin, `© OpenStreetMap` attribution, and a top-right `✕` clear button when the field is optional (omitted when required); below it, a coordinates row with a pin icon, 6-decimal monospace coordinates (`38.710841, -9.137265`), optional accuracy (`±12 m`), and a `Copy coordinates` icon button; below that, a two-button row with `Current location` and `Move pin`. Tapping the mini map or `Move pin` SHALL open the map picker.
4. **Has value · preview off:** When `show_map_preview` is off, shows a single input row with a pin icon, 6-decimal monospace coordinates, an `✕` clear button when optional, and a trailing map-picker icon button (`ph-map-trifold`).
5. **Has value · offline (or uncached without tile access):** Coordinates, copy, and `Current location` SHALL work offline. Where the `132px` mini map would appear, the field SHALL render a striped placeholder with `ph-wifi-slash` and `Map needs internet`.
6. **Location permission off:** When OS location permission for Fi is denied, shows the action buttons (`Current location` and `Pick on map`) with an inline alert below reading `Location access is off for Fi` (`ph-gps-slash`) and a `Settings` action that opens the app's OS settings page. `Pick on map` and `Type coordinates` SHALL remain usable.
7. **Location turned off on device:** When the device's location service is turned off, shows an inline alert reading `Location is off on this phone` (`ph-gps-slash`) with a `Turn on` action that opens the OS location toggle/settings and retries once enabled.
8. **Approximate location only (Android 12+):** When Android grants approximate (`ACCESS_COARSE_LOCATION`) but not precise (`ACCESS_FINE_LOCATION`) permission, saves the fix rounded to 4 decimal places (`38.7102, -9.1380`, `±1.9 km`) and shows a warning row below reading `Approximate location. The pin may be off by streets.` with an `Allow precise` action that requests precise location permission.
9. **Required · empty after save:** When a required `Location` field is empty after a save attempt, highlights the `Current location` and `Pick on map` buttons with a danger border and shows `Required` below them. A required `Location` field SHALL never show the `✕` clear button when populated.

#### Scenario: Empty to locating to saved fix
- **WHEN** the user taps `Current location` on an empty optional `Location` field with precise location permission granted and a GPS fix of `±12 m` arrives within 10 seconds
- **THEN** the field shows `Finding you…` while locating and transitions to the populated state showing the `132px` mini map, `38.710841, -9.137265`, `±12 m`, the copy button, `Current location`, and `Move pin`

#### Scenario: Preview off single row
- **WHEN** a `Location` field has `show_map_preview` set to `false` and holds `38.710841, -9.137265`
- **THEN** the record form renders a single row with the pin icon, `38.710841, -9.137265`, the `✕` clear button (when optional), and the trailing map-picker icon button, without a `132px` mini map

#### Scenario: Offline placeholder
- **WHEN** the device is offline, tiles for the saved coordinates are not in the disk cache, and `show_map_preview` is `true`
- **THEN** the `132px` map slot renders the striped placeholder reading `Map needs internet`, while the coordinates, `Copy coordinates`, and `Current location` remain functional

#### Scenario: Approximate location on Android 12+
- **WHEN** Android grants only approximate location and the user taps `Current location`
- **THEN** the fix is stored and displayed rounded to 4 decimals with its accuracy (e.g. `±1.9 km`), and the warning `Approximate location. The pin may be off by streets.` with `Allow precise` is shown below

#### Scenario: Permission denied inline alert
- **WHEN** the user denies location permission and taps `Current location`
- **THEN** the field displays `Location access is off for Fi` with `Settings`, and tapping `Pick on map` still opens the map picker

### Requirement: Inline location permission primer
On Android, the first time the user taps `Current location` before OS location permissions have been requested, the field SHALL show an inline permission primer card titled `Save where you are` explaining that Fi reads location only when `Current location` or the map is used and stores it only in the record, with a note to pick `Precise` for exact spots and two actions: `Not now` and `Continue`. `Not now` SHALL close the primer and leave the field empty; `Continue` SHALL trigger the OS location permission request and proceed to locating if granted. Once shown, the primer SHALL NOT be shown again on subsequent taps.

#### Scenario: First tap shows primer
- **WHEN** the user taps `Current location` for the first time on Android
- **THEN** the inline primer `Save where you are` is shown in the field with `Not now` and `Continue` before any OS permission dialog opens

#### Scenario: Not now dismisses primer
- **WHEN** the user taps `Not now` on the location permission primer
- **THEN** the primer closes, no OS permission request is made, and `Pick on map` remains usable

### Requirement: Interactive map picker and reverse-geocoded hint
Opening the map picker (`Pick on map`, `Move pin`, or tapping the mini map) SHALL open a full-screen map picker on phone widths (`< 720px`) or a modal map picker dialog on desktop widths (`>= 720px`).
- The map SHALL open centered on the field's saved coordinates if present, otherwise the user's current location if available, otherwise the last location used in the session.
- A pin SHALL stay fixed in the center of the map viewport while panning and zooming move the map underneath it.
- When the user's current location is known, the map SHALL render a live blue dot (`You are here`) and a floating target button (`Go to my location`, `ph-gps-fix`) that recenters the map on the user.
- The top bar SHALL carry a back/close button and a `Search places` pill input.
- The bottom sheet/panel SHALL show the field name, the guidance `Drag the map; the pin stays put`, the live center coordinates in 6-decimal monospace with a `Type` button (`ph-pencil-simple`), a live reverse-geocoded hint line (`Near <street/place> · <distance> from you` when online, omitted or distance-only when offline), and `Cancel` and `Use this spot` buttons.
- The reverse-geocoded street address SHALL be a live visual hint only and MUST NOT be stored in the record value.
- Tapping `Use this spot` SHALL set the field value to the center pin's coordinates (with no GPS accuracy badge, since it was placed on the map) and close the picker.

#### Scenario: Pan map and confirm spot
- **WHEN** the user opens the map picker, pans the map to `38.711923, -9.136410`, and taps `Use this spot`
- **THEN** the picker closes and the field holds `38.711923, -9.136410` with no reverse-geocoded address stored in the record

#### Scenario: Recenter on user location
- **WHEN** the user pans away from their current location in the map picker and taps the `Go to my location` button
- **THEN** the map recenters on the user's current coordinates

### Requirement: Place search with Photon
Tapping `Search places` in the map picker SHALL open the place search overlay:
- After the user types 3 or more characters, Fi SHALL query the free Photon OpenStreetMap geocoder (`https://photon.komoot.io/api/`) biased to the current map center, without requiring an API key.
- Results SHALL be listed nearest-first with the matching query substring highlighted in bold, a subtitle showing street/city context, and the distance from the user (or map center) in tabular numerals (`1.4 km`, `140 m`).
- A persistent `Type coordinates instead` row (`ph-hash`) and `Results from OpenStreetMap · nearest first` caption SHALL sit at the bottom of the results list.
- When the device is offline or the search request fails due to no connection, the overlay SHALL display `Search needs internet` and keep the `Type coordinates instead` action available.
- Selecting a search result SHALL close the search overlay and move the map picker's center pin to that result's coordinates; the field value is not saved until the user taps `Use this spot`.

#### Scenario: Type-ahead search moves pin
- **WHEN** the user types `time o` in `Search places` and taps `Time Out Market Lisboa`
- **THEN** the search overlay closes and the map picker centers on `Time Out Market Lisboa`'s coordinates ready for `Use this spot`

#### Scenario: Search while offline
- **WHEN** the device is offline and the user opens `Search places`
- **THEN** the overlay shows `Search needs internet` and offers `Type coordinates instead`

### Requirement: Type coordinates and map links
Tapping `Type` in the map picker bottom sheet or `Type coordinates instead` in place search SHALL open the `Type coordinates` sheet/dialog:
- It SHALL provide a single paste/parse input labelled `Coordinates or a map link` plus two side-by-side inputs labelled `Latitude` and `Longitude` that stay in sync: pasting or typing a valid coordinate or link into the top box fills both `Latitude` and `Longitude` and shows `Found <lat>, <lng>` in green (`ph-check-circle`), while editing `Latitude` or `Longitude` updates the coordinate pair.
- The parser SHALL accept:
  - Plain decimal coordinate pairs (`38.7139, -9.1334` or whitespace-separated);
  - Degrees, minutes, seconds (`38°42'50"N 9°08'00"W`);
  - `geo:` URIs (`geo:38.7139,-9.1334?q=...`);
  - Full Google Maps URLs (`@lat,lng`, `?q=lat,lng`, `query=lat,lng`, `!3d<lat>!4d<lng>`), Waze URLs (`ll=lat,lng`), and OpenStreetMap URLs (`#map=zoom/lat/lng`, `mlat`/`mlon`);
  - Short Google Maps share links (`https://maps.app.goo.gl/...` and `https://goo.gl/maps/...`) by resolving their HTTP redirect `Location` header when online (up to 3 redirect hops) and parsing the resulting full URL. When offline, a short link SHALL report that resolving a short map link requires internet.
- Invalid syntax SHALL show the error `Not a coordinate. Try 38.7139, -9.1334`. Out-of-range values SHALL show `Latitude goes from -90 to 90` or `Longitude goes from -180 to 180`.
- Tapping `Show on map` SHALL move the map picker's center pin to the parsed coordinates and return to the map picker so the user confirms with `Use this spot`.

#### Scenario: Paste full Google Maps link
- **WHEN** the user pastes `maps.google.com/?q=38.7139,-9.1334` into `Coordinates or a map link`
- **THEN** the sheet shows `Found 38.713900, -9.133400`, fills `Latitude` with `38.713900` and `Longitude` with `-9.133400`, and tapping `Show on map` centers the map picker on those coordinates

#### Scenario: Paste short Google Maps link online
- **WHEN** the user pastes `https://maps.app.goo.gl/Hxixt5WMth3JkB8J7f` while online and the short link redirects to a Google Maps URL containing `38.7139, -9.1334`
- **THEN** Fi resolves the redirect header, populates `38.713900` and `-9.133400`, and shows `Found 38.713900, -9.133400`

#### Scenario: Parse DMS coordinates
- **WHEN** the user enters `38°42'50"N 9°08'00"W`
- **THEN** the parser converts the DMS pair to decimal degrees (`38.713889, -9.133333`) and populates `Latitude` and `Longitude`

#### Scenario: Out of range latitude
- **WHEN** the user enters `95.0, -9.1334`
- **THEN** the sheet shows `Latitude goes from -90 to 90` and disables `Show on map`

### Requirement: Persistent tile disk cache and mobile data safeguard
Map tiles fetched for mini-map previews, mobile card thumbnails, and the interactive map picker SHALL be cached on disk in the application's cache directory with a bounded LRU budget so previously viewed locations render without re-downloading tiles across app restarts or while offline.
- Cached tiles SHALL always render immediately regardless of network state (Wi-Fi, mobile data, or offline).
- When the device is on a metered mobile data connection (`NetworkKind.mobile`), uncached map tiles SHALL NOT be auto-fetched for background record card thumbnails in the collection list; those thumbnails SHALL only render if already present in the disk cache.
- When the user is on Wi-Fi/Ethernet, or when the user actively opens the record editor form or the interactive map picker, uncached tiles SHALL be fetched on demand and stored in the disk cache.

#### Scenario: Cached tile renders offline
- **WHEN** a location's map tile was previously viewed on Wi-Fi and the device later goes offline
- **THEN** the map preview renders from the local disk cache without network traffic

#### Scenario: Mobile data suppresses uncached card list thumbnail fetches
- **WHEN** the device is on mobile data (`NetworkKind.mobile`) and the user scrolls a collection list containing records with uncached `Location` coordinates
- **THEN** Fi does not fetch uncached thumbnail tiles over mobile data while scrolling the list, and displays the coordinates and external map buttons

### Requirement: View mode and external map links
In view mode (anywhere a record is read rather than edited), opening or copying a location SHALL never modify the record value:
- **Desktop records table (`>= 720px`):** A populated `Location` cell SHALL display a pin icon and 4-decimal monospace coordinates (`38.7108, -9.1373`), or `—` when empty. Hovering or focusing the row/cell SHALL reveal quick icon buttons for `Google Maps` (`ph-google-logo`) and `Waze` (`ph-navigation-arrow`). Clicking the coordinates SHALL open the `Open in` menu.
- **Mobile record card (`< 720px`):** A populated `Location` field on a card SHALL display a `64×64` map thumbnail with a centered pin when `show_map_preview` is enabled (and the tile is cached or the device is on Wi-Fi), the field name, 4-decimal monospace coordinates (`38.7139, -9.1334`), and side-by-side `Google Maps` and `Waze` secondary buttons.
- **`Open in` menu & external URLs:**
  - `Open in Google Maps`: launches `https://www.google.com/maps/search/?api=1&query=<lat>,<lng>` (6 decimals);
  - `Navigate with Waze`: launches `https://waze.com/ul?ll=<lat>,<lng>&navigate=yes` (6 decimals);
  - `Open in another app…` (Android only): launches the Android intent chooser for `geo:<lat>,<lng>?q=<lat>,<lng>`;
  - `Copy coordinates`: copies `<lat>, <lng>` formatted to 6 decimal places (or 4 decimal places if the stored fix is marked approximate) to the clipboard.

#### Scenario: Desktop table cell hover and menu
- **WHEN** a record holds `38.710841, -9.137265` for `place` and the user views the desktop records table
- **THEN** the cell reads `38.7108, -9.1373`, hovering reveals the Google Maps and Waze icon buttons, and clicking the coordinates opens the menu with `Open in Google Maps`, `Navigate with Waze`, and `Copy coordinates`

#### Scenario: Copy coordinates uses full 6-decimal precision
- **WHEN** the user chooses `Copy coordinates` on a cell displaying `38.7108, -9.1373` for stored value `38.710841, -9.137265`
- **THEN** the clipboard receives `38.710841, -9.137265`
