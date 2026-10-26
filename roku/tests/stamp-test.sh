#!/bin/bash
# A release build keeps the data names every installed copy has: only an
# NX_TEST_DATA=1 deploy.sh build gets its own registry sections and cachefs:
# folder (nx_data_ns, scripts/stamp-manifest.sh). Run by tests/run.sh.
set -euo pipefail
cd "$(dirname "$0")/.."
fail() { echo "FAIL stamp: $*" >&2; exit 1; }
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

! grep -q '^nx_data_ns=' manifest || fail "the repo's manifest has nx_data_ns"

# release.sh's call, even with NX_TEST_DATA=1 in the environment.
scripts/stage.sh "$tmp/release" >/dev/null
release=$(NX_TEST_DATA=1 scripts/stamp-manifest.sh "$tmp/release")
grep -qx "nx_build=$release" "$tmp/release/manifest" || fail "no nx_build=$release in a release stamp"
! grep -q '^nx_data_ns=' "$tmp/release/manifest" || fail "a release stamp wrote nx_data_ns"

# deploy.sh's test-data call: the same hash, and the data space.
scripts/stage.sh "$tmp/test" >/dev/null
test=$(scripts/stamp-manifest.sh "$tmp/test" --test-data)
[ "$test" = "$release" ] || fail "the test-data build hashed $test, the release $release"
grep -qx 'nx_data_ns=nxtest' "$tmp/test/manifest" || fail "a test-data stamp has no nx_data_ns=nxtest"

# Stamping twice, or with a stray flag, is refused.
! scripts/stamp-manifest.sh "$tmp/release" 2>/dev/null >/dev/null || fail "a stamped manifest was stamped again"
scripts/stage.sh "$tmp/odd" >/dev/null
! scripts/stamp-manifest.sh "$tmp/odd" --test 2>/dev/null >/dev/null || fail "an unknown flag was taken"

# release.sh stamps through the plain call only, and refuses nx_data_ns.
calls=$(grep -c 'stamp-manifest.sh' scripts/release.sh)
[ "$calls" = 1 ] || fail "release.sh calls stamp-manifest.sh $calls times"
grep -q 'build=$(scripts/stamp-manifest.sh "$stage")$' scripts/release.sh || fail "release.sh's stamp call isn't the plain one"
! grep -q 'test-data\|NX_TEST_DATA' scripts/release.sh || fail "release.sh mentions the test-data stamp"
grep -q "^if grep -q '^nx_data_ns=' \"\$stage\"/manifest; then die" scripts/release.sh || fail "release.sh lost its nx_data_ns guard"

echo "stamp: a release keeps its data names; a test-data build gets nxtest"
