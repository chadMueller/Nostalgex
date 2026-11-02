#!/bin/bash
# Times the schedule pack on a real Apple TV: what a tune waits for on the main thread when the
# day isn't packed yet, packing each channel alone (before the lineup) and packing the lineup's
# day (after). The app does the timing itself (Nostalgex/Nostalgex/Services/ScheduleTiming.swift)
# in a scratch manifest folder, so the TV's own schedules are not touched; the TV must be signed
# in with its library already loaded once.
#
#   scripts/qa/appletv-schedule-timing.sh --device <devicectl id or name> [--runs 3] [--skip-install]
#
# Without --skip-install it builds Release for the device and installs it over what is there
# (a development build replaces a TestFlight or App Store one; the app's data stays). Only with
# the device owner's OK. The results print here and land in soak-results.log in the container.
set -euo pipefail
cd "$(dirname "$0")/../.."

device="" runs=3 install=1
while [ $# -gt 0 ]; do
    case $1 in
        --device) device=$2; shift 2 ;;
        --runs) runs=$2; shift 2 ;;
        --skip-install) install=0; shift ;;
        *) echo "unknown argument $1" >&2; exit 2 ;;
    esac
done
[ -n "$device" ] || { echo "usage: $0 --device <devicectl id or name> [--runs N] [--skip-install]" >&2; exit 2; }
bundle=com.muellhaus.nostalgex
work=$(mktemp -d "${TMPDIR:-/tmp}/nx-sched-timing.XXXXXX")
trap 'rm -rf "$work"' EXIT

if [ "$install" = 1 ]; then
    if pgrep -x xcodebuild >/dev/null; then echo "another xcodebuild is running; try again when it ends" >&2; exit 3; fi
    # xcodebuild wants the hardware UDID, devicectl takes its own id or the name.
    xcrun devicectl list devices --json-output "$work/devices.json" >/dev/null
    udid=$(node -e '
      const d = JSON.parse(require("fs").readFileSync(process.argv[1])).result.devices;
      const want = process.argv[2];
      const m = d.find((x) => x.identifier === want || x.deviceProperties?.name === want || x.hardwareProperties?.udid === want);
      if (!m) { console.error("no device " + want); process.exit(1); }
      console.log(m.hardwareProperties.udid);' "$work/devices.json" "$device")
    xcodebuild build -project Nostalgex/Nostalgex.xcodeproj -scheme Nostalgex -configuration Release \
        -destination "platform=tvOS,id=$udid" -derivedDataPath "$work/dd" -allowProvisioningUpdates \
        -authenticationKeyPath ~/.appstoreconnect/AuthKey_BF3LR5NQQK.p8 -authenticationKeyID BF3LR5NQQK \
        -authenticationKeyIssuerID e9e9d3ec-0c04-4694-bcb9-55e8407672f6 DEVELOPMENT_TEAM=KK5V95295A \
        > "$work/build.log" 2>&1 || { tail -30 "$work/build.log" >&2; exit 1; }
    app=$(find "$work/dd/Build/Products/Release-appletvos" -maxdepth 1 -name "*.app" | head -1)
    xcrun devicectl device install app --device "$device" "$app"
fi

printf 'sched-timing:%s\n' "$runs" > "$work/soak.trigger"
xcrun devicectl device copy to --device "$device" --domain-type appDataContainer --domain-identifier "$bundle" \
    --source "$work/soak.trigger" --destination Library/Caches/Nostalgex/soak.trigger >/dev/null
xcrun devicectl device process launch --device "$device" --terminate-existing "$bundle" >/dev/null
echo "launched; waiting for the timing (up to 10 minutes)"

for _ in $(seq 1 60); do
    sleep 10
    if xcrun devicectl device copy from --device "$device" --domain-type appDataContainer --domain-identifier "$bundle" \
        --source Library/Caches/Nostalgex/soak-results.log --destination "$work/results.log" >/dev/null 2>&1 \
        && grep -q '\[sched-timing\] done' "$work/results.log"; then
        grep '\[sched-timing\]' "$work/results.log"
        exit 0
    fi
done
echo "no result after 10 minutes" >&2
[ -f "$work/results.log" ] && tail -20 "$work/results.log" >&2
exit 1
