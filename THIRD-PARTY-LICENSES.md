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

## Swift packages

| Package | License |
|---|---|
| TelemetryDeck SwiftSDK (github.com/TelemetryDeck/SwiftSDK) | MIT |
