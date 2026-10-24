#!/bin/bash
# Run the golden-vector tests off-device in the RokuCommunity brs interpreter.
# The interpreter is a first check only: it gets some LongInteger operations
# wrong, and the port avoids those, but a pass here is confirmed on a TV with
# `scripts/deploy.sh --test`.
#
# The port lives at roku/ in the Nostalgex repo. data/ holds symlinks to the
# repo root's channels.json, channels-memberships.json and franchises.json, and
# tests/vectors/ is generated here, on every run, from the same tree's JS
# engine, so the port is always checked against the code and data it ships
# next to. An outside $NOSTALGEX_DIR is ignored: the vectors and data/ must
# come from one tree.
set -euo pipefail
cd "$(dirname "$0")/.."
upstream=$(cd .. && pwd)
for f in channels.json channels-memberships.json franchises.json; do
    [ -f "data/$f" ] || { echo "FAIL data/$f does not resolve; it links to the repo root's $f" >&2; exit 1; }
done
# Upstream's own builder, filter, ratings and seasons must pass their golden files, or
# the files prove nothing, and its collections module its own smoke test, or
# the vectors from it don't.
(cd "$upstream" && node scripts/nostalgex-franchise-smoke.mjs && node scripts/nostalgex-filter-golden-smoke.mjs && node scripts/nostalgex-rating-smoke.mjs && node scripts/nostalgex-collections-smoke.mjs && node scripts/nostalgex-season-smoke.mjs)
NOSTALGEX_DIR=$upstream node tests/gen-vectors.mjs
# Secrets never reach the debug console, which anyone on the network can read:
# no print statement may output a variable named like a token, URL or header.
# Quoted text is ignored, so a message may say "token".
leaks=$(grep -rnE '^\s*print\b' source components | perl -ne '
    my ($loc, $code) = /^([^:]+:\d+):(.*)$/; $code =~ s/"(?:[^"]|"")*"//g;
    print "$loc\n" if $code =~ /token|\buri\b|\burl\b|header/i;')
if [ -n "$leaks" ]; then
    echo "FAIL a print statement may output a secret:" >&2
    echo "$leaks" >&2
    exit 1
fi

python3 tests/tools/check-includes.py

# `m` is BrightScript's implicit this: a variable of that name silently holds
# the component's AA instead. It has cost three debugging rounds; fail fast.
shadow=$(grep -rnE '^\s*(for\s+)?m\s*=[^=]|\bas\s+\w+\s*,?\s*m\s+as\b|\(\s*m\s+as\b' source components tests --include=*.brs || true)
if [ -n "$shadow" ]; then
    echo "FAIL a variable named m (BrightScript's this):" >&2
    echo "$shadow" >&2
    exit 1
fi

# `run` names Roku's builtin Run(): a TV refuses it as a variable or
# parameter ("Builtin function call expected") though the interpreter takes
# it, so a build that passes here wouldn't start.
builtin=$(grep -rnEi '^\s*(for\s+)?run\s*=[^=]|[(,]\s*run\s+as\b' source components tests --include=*.brs || true)
if [ -n "$builtin" ]; then
    echo "FAIL a variable named run (Roku's Run()):" >&2
    echo "$builtin" >&2
    exit 1
fi

brs=$(npx -y -p @rokucommunity/brs@0.47.6 -c 'command -v brs')

# The components never run here, so a parse error in one (a reserved word
# such as `box` or `pos` as a name) would show only on a TV: parse each, all
# at once.
# getconf, not nproc: macOS has no nproc.
cpus=$(getconf _NPROCESSORS_ONLN)
bad=$(printf '%s\0' components/*.brs | xargs -0 -P "$cpus" -I{} sh -c '
    "$1" --root . "$2" 2>&1 | grep -q "Error occurred parsing" && echo "$2"' _ "$brs" {} || true)
if [ -n "$bad" ]; then
    for f in $bad; do
        echo "FAIL $f doesn't parse:" >&2
        "$brs" --root . "$f" 2>&1 | grep -v "^Warning: XML" | head -5 >&2
    done
    exit 1
fi

# Each suite in tests/main.brs runs in its own interpreter, all at once, and
# the two slowest split across several: the filter vectors by channel (345 s
# in one), the QR codes by case (71 s). out/test-parts/<part>.brs defines
# NxTestShard for that interpreter. The suites are read from main.brs, so
# none is left out. Plain variables, not an associative array: macOS's
# /bin/bash is 3.2.
filter_parts=${NX_FILTER_SHARDS:-10}
qr_parts=${NX_QR_SHARDS:-4}
parts=out/test-parts
rm -rf "$parts" && mkdir -p "$parts"
suites=$(grep -oE 'NxTestWants\("[a-z-]+"\)' tests/main.brs | sed -E 's/.*"(.*)".*/\1/')
[ -n "$suites" ] || { echo "FAIL no NxTestWants suites found in tests/main.brs" >&2; exit 1; }
for suite in $suites; do
    case $suite in
        filter) n=$filter_parts ;;
        qr) n=$qr_parts ;;
        *) n=1 ;;
    esac
    [[ $n =~ ^[1-9][0-9]*$ ]] || { echo "FAIL $suite would split into '$n' parts; give 1 or more" >&2; exit 1; }
    for i in $(seq 0 $((n - 1))); do
        printf 'function NxTestShard() as Dynamic\n    return { suite: "%s", index: %d, count: %d }\nend function\n' "$suite" "$i" "$n" >"$parts/$suite-$i.brs"
    done
done
files=(tests/main.brs tests/runtime-interpreter.brs tests/ScheduleTests.brs tests/FilterTests.brs tests/FilterGoldenTests.brs tests/RatingGoldenTests.brs tests/LineupTests.brs tests/ScheduleDSTGoldenTests.brs tests/ScheduleParityTests.brs tests/FranchiseTests.brs tests/FranchiseGuideTests.brs tests/EnrichmentTests.brs tests/SubtitleTests.brs tests/GuideNavTests.brs tests/TuneQueueTests.brs tests/AdvanceTests.brs tests/FallbackTests.brs tests/SleepTimerTests.brs tests/DeepLinkTests.brs tests/CollectionTests.brs tests/ServerChoiceTests.brs tests/ServerResolveTests.brs tests/SnapshotTests.brs tests/SeasonalTests.brs tests/MediaBrowserTests.brs tests/SignInFlowTests.brs tests/QrTests.brs tests/VersionTests.brs source/plex/ServerChoice.brs source/plex/ServerResolve.brs source/plex/LibrarySnapshot.brs source/plex/PlexLibrary.brs source/plex/PlexApi.brs source/plex/PlexPlayback.brs source/util/*.brs source/schedule/*.brs source/filter/*.brs source/guide/*.brs source/franchise/*.brs source/enrich/*.brs source/subtitles/*.brs source/collections/*.brs source/mediabrowser/*.brs)
# One part per CPU thread at a time ($NX_TEST_JOBS overrides), the split
# suites' parts first, so the small ones fill in around them.
jobs=${NX_TEST_JOBS:-$cpus}
export brs
{ ls "$parts"/filter-*.brs "$parts"/qr-*.brs; ls "$parts"/*.brs | grep -v -e /filter- -e /qr-; } |
    xargs -P "$jobs" -I{} sh -c '"$brs" --root . "$@" "$0" >"${0%.brs}.log" 2>&1' {} "${files[@]}" || true
# A part that crashed has no ALL TESTS PASSED line, so the check below fails it.
failed=0
for part in "$parts"/*.brs; do
    log=${part%.brs}.log
    grep -v '^ALL TESTS PASSED$' "$log"
    grep -qx 'ALL TESTS PASSED' "$log" || { echo "FAIL part $(basename "${part%.brs}") did not pass (full output in $log)" >&2; failed=1; }
done
[ "$failed" = 0 ] || { echo "TESTS FAILED"; exit 1; }
echo "ALL TESTS PASSED"
