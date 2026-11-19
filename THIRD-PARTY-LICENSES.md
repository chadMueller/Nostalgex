# Third-party licenses

Nostalgex itself is MIT (see `LICENSE`). It ships with the following third-party work.

## Fonts (bundled in the tvOS app)

| Font | Copyright | License |
|---|---|---|
| VT323 | 2011, The VT323 Project Authors (peter.hull@oikoi.com) | SIL Open Font License 1.1, `Nostalgex/Nostalgex/OFL-VT323.txt` |
| DM Mono | 2020, The DM Mono Project Authors (github.com/googlefonts/dm-mono) | SIL Open Font License 1.1, `Nostalgex/Nostalgex/OFL-DMMono.txt` |

The web tuner serves DM Mono (Regular and Medium) itself, from `tuner/fonts/`, with the license text beside the files (`tuner/fonts/OFL-DMMono.txt`). The same files are in the Docker image. VT323 for the tuner and the site's other fonts load from Google Fonts at runtime on nostalgex.app and are not redistributed there.

## Self-hosted web tuner (Docker image)

The image (`npm run build:selfhost`) bundles these from npm instead of loading them from a CDN. Each license ships in the image under `vendor/licenses/`.

| Package | License |
|---|---|
| hls.js 1.5.17 | Apache License 2.0 |
| qrcodejs 1.0.0 | MIT |
| VT323, Space Mono, Bricolage Grotesque (via @fontsource) | SIL Open Font License 1.1 |
| DM Mono Regular and Medium (`tuner/fonts/`, license in `vendor/licenses/OFL-DMMono.txt`) | SIL Open Font License 1.1 |
| nginx (base image `nginxinc/nginx-unprivileged`) | 2-clause BSD |

## Weather channel (web tuner and Docker image)

The LOCAL WEATHER channel (CH 299) draws its own screens and uses these data sources. The credit shows on the channel and in Settings.

| Source | Used for | License and credit |
|---|---|---|
| MET Norway, Locationforecast 2.0 (api.met.no), through the relay at `api/weather.js` | The forecast | CC BY 4.0 and NLOD 2.0. "Data from MET Norway." Rearranged for display. https://creativecommons.org/licenses/by/4.0/ |
| GeoNames (geonames.org), cities5000 and postal code files | The place list a viewer types into, shipped as static files under `weather/places/` (built by `scripts/build-weather-data.mjs`) | CC BY 4.0. Place names from GeoNames. Only the outward part of a UK postcode is kept. |
| Natural Earth (naturalearthdata.com), 1:50m coastline, lakes and boundary lines | The map drawn under the radar (`weather/basemap.json`) | Public domain. |
| US National Weather Service, MRMS composite reflectivity (opengeo.ncep.noaa.gov) | Radar for the United States | Public domain (weather.gov/disclaimer). Not presented as official NWS material. |
| Environment and Climate Change Canada, GeoMet (geo.weather.gc.ca), RADAR_1KM_RRAI and RADAR_1KM_RSNO | Radar for Canada | ECCC data licence, commercial use allowed. "Data Source: Environment and Climate Change Canada." |
| Deutscher Wetterdienst, Niederschlagsradar (maps.dwd.de) | Radar for Germany | CC BY 4.0 for DWD's freely accessible geodata and geodata services, with a source note (https://www.dwd.de/DE/service/rechtliche_hinweise/rechtliche_hinweise_node.html). Shown as DWD's own wording for changed data: "Datenbasis: Deutscher Wetterdienst, Rasterdaten bildlich wiedergegeben" (https://www.dwd.de/DE/service/rechtliche_hinweise/vorlagen_quellenangabe.html). Recolored to our five bands. |
| The weather channel's music, `public/weather/music/local-forecast.m4a` and `.mp3` | A quiet loop under the screens | Original: composed for Nostalgex as MIDI (`scripts/weather-music/compose.py`, MIT like the rest of the repo) and rendered with the FluidR3_GM sound set (Frank Wen 2000-2002, Toby Smithe 2008, MIT; notice in `public/weather/music/LICENSE-FluidR3_GM.txt`; `scripts/weather-music/render.sh`). The sound set itself is not shipped. No recording, score or melody of anyone else is used. |

The Yr name and logo are not used, and the channel does not copy the look of Yr or of any other weather service.

## Roku app (`roku/`)

The Roku port is contributed work under its own MIT license, copyright the
nostalgex-roku contributors with portions copyright Chad Mueller / Muell Haus
Inc.: see `roku/LICENSE`, which applies to everything under `roku/`. The Roku
package bundles the same two fonts as the tvOS app, with their license texts in
`roku/fonts/` (`roku/THIRD-PARTY-LICENSES.md`):

| Font | License |
|---|---|
| DM Mono | SIL Open Font License 1.1, `roku/fonts/OFL-DMMono.txt` |
| VT323 | SIL Open Font License 1.1, `roku/fonts/OFL-VT323.txt` |

Its sign-in QR code is drawn on the TV by `roku/source/util/QrCode.brs`, which
follows the design of Project Nayuki's QR Code generator library (MIT License),
credited in `roku/THIRD-PARTY-LICENSES.md`.

## Android TV app (`android/`)

The Android TV app bundles the same two fonts, with their license texts in
`android/`:

| Font | License |
|---|---|
| DM Mono | SIL Open Font License 1.1, `android/OFL-DMMono.txt` |
| VT323 | SIL Open Font License 1.1, `android/OFL-VT323.txt` |

Its libraries, fetched by Gradle and compiled into the APK:

| Library | License |
|---|---|
| AndroidX (Media3, Compose, Compose for TV, Activity) | Apache License 2.0 |
| Kotlin standard library, kotlinx.coroutines, kotlinx.serialization | Apache License 2.0 |
| OkHttp | Apache License 2.0 |
| ZXing core (the sign-in QR code) | Apache License 2.0 |

## Swift packages

| Package | License |
|---|---|
| TelemetryDeck SwiftSDK (github.com/TelemetryDeck/SwiftSDK) | MIT |
