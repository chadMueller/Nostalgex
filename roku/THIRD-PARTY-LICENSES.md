# Third-party licenses

## Fonts (bundled in `fonts/`)

The same two fonts the Nostalgex Apple TV app bundles, from
[google/fonts](https://github.com/google/fonts).

| Font | Copyright | License |
|------|-----------|---------|
| DM Mono (Regular, Medium) | 2020, The DM Mono Project Authors (github.com/googlefonts/dm-mono) | SIL Open Font License 1.1, `fonts/OFL-DMMono.txt` |
| VT323 | 2011, The VT323 Project Authors (peter.hull@oikoi.com) | SIL Open Font License 1.1, `fonts/OFL-VT323.txt` |

## Nostalgex

Portions are ported from [Nostalgex](https://github.com/chadMueller/Nostalgex),
copyright Chad Mueller / Muell Haus Inc., MIT License. See [LICENSE](LICENSE).

The Nostalgex wordmark in `images/` (`logo.png`, the icons and splash) is
upstream's brand, from its `logo/png/`, used at the maintainer's request.

## QR Code generator

`source/util/QrCode.brs` follows the design of Project Nayuki's
[QR Code generator library](https://www.nayuki.io/page/qr-code-generator-library),
copyright (c) Project Nayuki, MIT License: its Reed-Solomon blocks, function
patterns, codeword placement and mask penalty.

## Weather channel (CH 299 LOCAL WEATHER)

The channel draws its own screens and uses these data sources. The credit shows on the channel and in Settings.

| Source | Used for | License and credit |
|---|---|---|
| MET Norway, Locationforecast 2.0 (api.met.no), through the relay at nostalgex.app/api/weather | The forecast | CC BY 4.0 and NLOD 2.0. "Data from MET Norway." Rearranged for display. https://creativecommons.org/licenses/by/4.0/ |
| GeoNames (geonames.org), cities5000 and postal code files | The place list a viewer types into, static files under nostalgex.app/weather/places/ | CC BY 4.0. Place names from GeoNames. Only the outward part of a UK postcode is kept. |
| Natural Earth (naturalearthdata.com), 1:50m coastline, lakes and boundary lines | The map drawn under the radar (`weather/basemap.json`, the web tuner's copy) | Public domain. |
| US National Weather Service, MRMS composite reflectivity (opengeo.ncep.noaa.gov) | Radar for the United States | Public domain (weather.gov/disclaimer). Not presented as official NWS material. |
| Environment and Climate Change Canada, GeoMet (geo.weather.gc.ca), RADAR_1KM_RRAI and RADAR_1KM_RSNO | Radar for Canada | ECCC data licence, commercial use allowed. "Data Source: Environment and Climate Change Canada." |
| Deutscher Wetterdienst, Niederschlagsradar (maps.dwd.de) | Radar for Germany | CC BY 4.0 for DWD's freely accessible geodata services, with a source note: "Datenbasis: Deutscher Wetterdienst, Rasterdaten bildlich wiedergegeben". Recolored to our five bands. |
| The channel's music, `weather/local-forecast.mp3` | A quiet loop under the screens | Original: composed for Nostalgex as MIDI and rendered with the FluidR3_GM sound set (Frank Wen 2000-2002, Toby Smithe 2008, MIT; notice in `weather/LICENSE-FluidR3_GM.txt`). The sound set itself is not shipped. No recording, score or melody of anyone else is used. |

The Yr name and logo are not used, and the channel does not copy the look of Yr or of any other weather service.
