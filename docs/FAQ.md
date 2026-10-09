# FAQ and troubleshooting

## "Could not reach my server" (Jellyfin / Emby)

Work through these in order. Most reports are one of the four.

1. **Address.** Type the scheme, host and port exactly as another client uses them, for example `http://192.168.1.20:8096`. A `100.x.x.x` address is Tailscale.
2. **Read the error.** Since 1.0.23 the connect screen names the cause: transport security, unknown host, wrong port, timeout, or certificate. Each one points at a different fix.
3. **Does another app on the same Apple TV reach the same server?** If Swiftfin or the Jellyfin app connects and Nostalgex does not, open an issue with the exact address and the exact error text. If nothing connects, it is the network or the server, not the app.
4. **Plain http to a non-local address** (VPN, Tailscale, a public IP) was blocked by App Transport Security before 1.0.23. Update the app.

## Plex over Tailscale or VPN

Plex has no address field. The app can only see addresses that plex.tv advertises for your server. Add your VPN address under Plex Settings > Network > Custom server access URLs, then sign in again.

## A channel is empty, or a title is on the wrong channel

Channels are rules over your library's metadata, all in `channels.json`. An empty channel usually means your library has nothing that matches, or the server's genres and ratings are missing. A title in the wrong place is a rule that needs tightening. Open an issue with the title and the channel, or send a pull request against `channels.json`.

## It tunes but never plays, or plays sound over a black picture

First ask the server whether it can actually read the file. On Plex: `GET /library/metadata/<ratingKey>?checkFiles=1`. If it says `exists=false`, a disk is unmounted on the server and no client will play it. If the file exists and it still fails, open an issue with the container, video codec and audio codec and which Apple TV model you have.

## Known causes fixed in past releases

| Symptom | Cause | Fixed in |
|---|---|---|
| Jellyfin or Emby "could not reach" over Tailscale or VPN while other apps work | Transport security blocked plain http off the local network | 1.0.23 |
| Tuning screen never clears, fast channel changes fail | Playback decision call was skipped before the stream started | 1.0.21 |
| Sound over a black picture on re-encoded files (tvOS 26) | Timestamp handling on transcodes | 1.0.21 |
| Sign-in forgotten after a force quit | PIN sign-in was never saved | 1.0.17 |
| Guide rebuilt on every launch | Snapshot could not be written on device | 1.0.19 |

## Where to ask

Bugs and feature requests: GitHub Issues on this repo. Email: support@nostalgex.app. One person maintains this. You will get an answer, but not always the same day.
