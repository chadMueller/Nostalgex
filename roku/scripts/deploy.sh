#!/bin/bash
# Zip the channel and sideload it to every TV in ROKU_HOSTS (from .env, or the
# command line: ROKU_HOSTS=<tv-ip> scripts/deploy.sh), then launch it.
# Each TV holds one sideloaded channel; installing replaces it.
#
#   scripts/deploy.sh          the app
#   scripts/deploy.sh --test   a test build: tests/main.brs replaces the app's
#                              entry point, runs the golden vectors on the TV,
#                              and the result is read from its debug console
#                              (port 8085). Exits non-zero unless every TV passes.
#   scripts/deploy.sh --live   a live-check build: tests/live/LiveMain.brs loads
#                              the signed-in Plex library and prints fingerprints
#                              to out/live-<tv>.log for tests/live/compare.mjs.
#   scripts/deploy.sh --tour   the sign-in tour: the connect screens on their own
#                              (tests/signin), to walk with a remote and count
#                              presses. Relaunch with ?discovery=none|several to
#                              stand in for the network search.
set -euo pipefail
cd "$(dirname "$0")/.."
test_build=false
mode=app
case "${1:-}" in
    --test) test_build=true; mode=test ;;
    --live) test_build=true; mode=live ;;
    --tour) mode=tour ;;
esac
wait_s=${TEST_TIMEOUT:-600} # seconds to wait for a TV's test result
[ -f .env ] || { echo "no .env — copy .env.example" >&2; exit 1; }
# A ROKU_HOSTS given on the command line wins over .env's, to install to one TV.
hosts_override=${ROKU_HOSTS:-}
# shellcheck source=/dev/null
. ./.env
[ -n "$hosts_override" ] && ROKU_HOSTS=$hosts_override
: "${ROKU_HOSTS:?set ROKU_HOSTS in .env}" "${ROKU_DEV_PASSWORD:?set ROKU_DEV_PASSWORD in .env}"

stage=out/stage
rm -rf "$stage" out/nostalgex-roku.zip
scripts/stage.sh "$stage"
# Enrichment (source/enrich/Enrichment.brs) is in a build only when .env turns
# it on and gives the Supabase project; the values go into the zip, never the
# repo. Without them the app runs with no enrichment, as before.
rm -f "$stage"/data/enrichment.json
if [ "${NOSTALGEX_ENRICHMENT:-off}" = on ]; then
    url=${NOSTALGEX_SUPABASE_URL:-} key=${NOSTALGEX_SUPABASE_ANON_KEY:-}
    [[ $url =~ ^https://[A-Za-z0-9.-]+/?$ ]] || { echo "NOSTALGEX_ENRICHMENT=on needs NOSTALGEX_SUPABASE_URL (https://<project>.supabase.co)" >&2; exit 1; }
    [[ $key =~ ^[A-Za-z0-9._-]+$ ]] || { echo "NOSTALGEX_ENRICHMENT=on needs NOSTALGEX_SUPABASE_ANON_KEY" >&2; exit 1; }
    printf '{"supabaseURL":"%s","anonKey":"%s"}\n' "$url" "$key" >"$stage"/data/enrichment.json
    echo "build: enrichment on"
fi
if [ "$mode" = test ]; then
    cp tests/main.brs tests/runtime-device.brs tests/ScheduleTests.brs tests/FilterTests.brs tests/FilterGoldenTests.brs tests/RatingGoldenTests.brs tests/LineupTests.brs tests/ScheduleDSTGoldenTests.brs tests/FranchiseTests.brs tests/FranchiseGuideTests.brs tests/EnrichmentTests.brs tests/SubtitleTests.brs tests/GuideNavTests.brs tests/TuneQueueTests.brs tests/AdvanceTests.brs tests/FallbackTests.brs tests/SleepTimerTests.brs tests/DeepLinkTests.brs tests/CollectionTests.brs tests/ServerChoiceTests.brs tests/ServerResolveTests.brs tests/SnapshotTests.brs tests/StallTests.brs tests/SeasonalTests.brs tests/MediaBrowserTests.brs tests/SignInFlowTests.brs tests/QrTests.brs tests/VersionTests.brs "$stage"/source/
    # The vectors are generated from this tree's JS engine, never committed
    # (qr.json, from tests/gen-qr.mjs, is the one kept in git).
    NOSTALGEX_DIR=.. node tests/gen-vectors.mjs >/dev/null
    mkdir -p "$stage"/tests && cp -r tests/vectors tests/fixtures "$stage"/tests/
elif [ "$mode" = live ]; then
    cp tests/live/LiveMain.brs "$stage"/source/main.brs
elif [ "$mode" = tour ]; then
    cp tests/signin/SignInTourMain.brs "$stage"/source/main.brs
    cp tests/signin/SignInTourScene.xml tests/signin/SignInTourScene.brs "$stage"/components/
fi
# Which build this zip is, for the saved guide and pools' keys: a sideload
# keeps the manifest's version, so without it a build installed over another
# reused the old one's filter results (components/LibraryTask.brs
# NxBuildKey). A hash of every staged file, so it holds from a copy without
# git too (the personal repo's build/).
# LC_ALL=C: sort's order, and so the hash, would otherwise follow the shell's
# locale (the 1.0.2 tree hashed cca0d38 under C and d27182e under en_US).
build=$(cd "$stage" && find . -type f -print0 | LC_ALL=C sort -z | xargs -0 sha1sum | sha1sum | cut -c1-12)
printf 'nx_build=%s\n' "$build" >>"$stage"/manifest
echo "build: $build"
(cd "$stage" && zip -qr ../nostalgex-roku.zip .)

failed=0
for host in $ROKU_HOSTS; do
    if $test_build; then
        # Connect to the debug console before installing, because installing
        # launches the app. On connect the console replays recent output, which
        # can hold an older run's result, so only what arrives after the replay
        # (past $mark) counts. `exec cat`: the listener's process is cat
        # itself, so killing it closes the console. A cat left as bash's
        # child held the TV's one console connection for hours (2026-10-21).
        log=out/$mode-"$host".log
        timeout "$((wait_s + 10))" bash -c 'exec 3<>"/dev/tcp/$0/8085" && exec cat <&3' "$host" >"$log" 2>&1 &
        listener=$!
        sleep 3
        mark=$(stat -c %s "$log")
    fi
    code=$(curl -s -o out/install-"$host".html -w '%{http_code}' --digest \
        -u "rokudev:$ROKU_DEV_PASSWORD" -F mysubmit=Install \
        -F "archive=@out/nostalgex-roku.zip" "http://$host/plugin_install")
    if [ "$code" != 200 ] || ! grep -qiE 'Install Success|Identical to previous' out/install-"$host".html; then
        echo "$host: install failed (HTTP $code) — see out/install-$host.html" >&2
        $test_build && kill "$listener" 2>/dev/null
        failed=1
        continue
    fi
    # Installing starts the app on most TVs; a second launch would race it.
    sleep 2
    if ! curl -s -m 5 "http://$host:8060/query/active-app" | grep -q 'id="dev"'; then
        curl -s -o /dev/null -X POST "http://$host:8060/launch/dev"
    fi
    if ! $test_build; then
        echo "$host: installed and launched"
        continue
    fi
    fresh() { tail -c +"$((mark + 1))" "$log" | tr -d '\r'; }
    for _ in $(seq 1 "$wait_s"); do
        fresh | grep -qE 'ALL TESTS PASSED|TESTS FAILED|LIVE DONE|LIVE FAILED|BrightScript Micro Debugger' && break
        sleep 1
    done
    kill "$listener" 2>/dev/null || true
    fresh | grep -E '^FAIL|^    (want|got)| vectors | took |filter: |TESTS|^LIVE |Micro Debugger|runtime error' | sed "s/^/$host: /" || true
    if ! fresh | grep -qE 'ALL TESTS PASSED|LIVE DONE'; then
        echo "$host: tests did not pass — full console in $log" >&2
        failed=1
    fi
done
exit $failed
