#!/bin/bash
# N-013: run ForcedSubtitleBurnHarness on a tvOS simulator against a lab server (or the logging proxy).
#
#   run-harness.sh CRED_FILE DERIVED_DATA SIM_ID OUT_PREFIX TESTS [BACKEND]
#
#   CRED_FILE     lab-setup.py output (url may point at logproxy.py); read here, never printed
#   DERIVED_DATA  where `xcodebuild build-for-testing` put the build
#   SIM_ID        a tvOS simulator UDID (not the one another agent has booted)
#   OUT_PREFIX    writes OUT_PREFIX.transcript.txt (harness) and OUT_PREFIX.xcodebuild.log
#   TESTS         A, B, C, D or any combination: ABCD
#   BACKEND       emby (default) or jellyfin
#
# Build once first:
#   xcodebuild build-for-testing -project Nostalgex/Nostalgex.xcodeproj -scheme Nostalgex \
#     -destination "platform=tvOS Simulator,id=$SIM" -derivedDataPath $DD -jobs 4
# Check `ps` for xcodebuild and `uptime` before running (AGENT-RULES).
set -euo pipefail
CRED="$1"; DD="$2"; SIM="$3"; OUT="$4"; TESTS="$5"; BACKEND="${6:-emby}"
field() { python3 -I -c "import json,sys;print(json.load(open('$CRED'))['$1'])"; }
export TEST_RUNNER_NOSTALGEX_FS_URL="$(field url)"
export TEST_RUNNER_NOSTALGEX_FS_TOKEN="$(field token)"
export TEST_RUNNER_NOSTALGEX_FS_USER="$(field userId)"
export TEST_RUNNER_NOSTALGEX_FS_BACKEND="$BACKEND"
export TEST_RUNNER_NOSTALGEX_FS_OUT="$OUT.transcript.txt"
export TEST_RUNNER_NOSTALGEX_FS_TITLES="${FS_TITLES:-Forced Lines Film,Forced And Full Film,Default Subs Film,Plain Control Film,Forced Spanish Film,Forced Lines MP4,Full HD Forced,HEVC Forced,Ten Bit Forced,HDR Forced}"
export TEST_RUNNER_NOSTALGEX_FS_OBSERVE="${FS_OBSERVE:-45}"
export TEST_RUNNER_NOSTALGEX_FS_POOL_FORCED="${FS_POOL_FORCED:-Forced Lines Film,Forced Lines Two,Forced Lines Three}"
export TEST_RUNNER_NOSTALGEX_FS_POOL_MIXED="${FS_POOL_MIXED:-Forced Lines Film,Plain Control Film,Plain Control Two,Forced Lines Two}"
export TEST_RUNNER_NOSTALGEX_FS_CHANNEL_SECONDS="${FS_CHANNEL_SECONDS:-150}"
ONLY=()
[[ "$TESTS" == *A* ]] && ONLY+=(-only-testing:NostalgexTests/ForcedSubtitleBurnHarness/testA_EachFilmThroughTheAppLoadPath)
[[ "$TESTS" == *D* ]] && ONLY+=(-only-testing:NostalgexTests/ForcedSubtitleBurnHarness/testD_PlayerLogsWhileTheBurnStreamIsRefused)
[[ "$TESTS" == *B* ]] && ONLY+=(-only-testing:NostalgexTests/ForcedSubtitleBurnHarness/testB_ChannelOfOnlyForcedFilms)
[[ "$TESTS" == *C* ]] && ONLY+=(-only-testing:NostalgexTests/ForcedSubtitleBurnHarness/testC_ChannelMixedForcedAndPlain)
rm -f "$OUT.transcript.txt"
cd "$(dirname "$0")/../../Nostalgex"
xcodebuild test-without-building -project Nostalgex.xcodeproj -scheme Nostalgex \
  -destination "platform=tvOS Simulator,id=$SIM" -derivedDataPath "$DD" \
  -parallel-testing-enabled NO "${ONLY[@]}" > "$OUT.xcodebuild.log" 2>&1 || true
grep -E "Test Case .* (passed|failed)|Executed [0-9]+ test|TEST (SUCCEEDED|FAILED)" "$OUT.xcodebuild.log" | tail -8
echo "transcript: $OUT.transcript.txt"
