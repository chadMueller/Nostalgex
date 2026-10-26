#!/bin/bash
# Stamp a staged app's manifest and print its build hash. Used by
# scripts/deploy.sh and scripts/release.sh, so both stamp alike.
#
#   scripts/stamp-manifest.sh STAGE               nx_build only
#   scripts/stamp-manifest.sh STAGE --test-data   and nx_data_ns=nxtest
#
# nx_build: which build the zip is, for the saved guide and pools' keys (a
# sideload keeps the manifest's version, so without it a build installed over
# another reused the old one's filter results; components/LibraryTask.brs
# NxBuildKey). A hash of every staged file, so it holds from a copy without
# git too. LC_ALL=C: sort's order, and so the hash, would otherwise follow the
# shell's locale (the 1.0.2 tree hashed cca0d38 under C and d27182e under
# en_US). The hash is taken before either line is added, so a test-data build
# has the same hash as the app build of the same tree.
#
# nx_data_ns: a test build's own registry sections and cachefs: folder
# (NxDataSpace in source/util/Values.brs), so a sideload can sign in to a lab
# server without touching the sign-in the store app shares with it. Only
# deploy.sh asks for it (NX_TEST_DATA=1); release.sh never does and refuses a
# manifest that has it.
set -euo pipefail
[ $# -ge 1 ] && [ $# -le 2 ] || { echo "usage: scripts/stamp-manifest.sh STAGE [--test-data]" >&2; exit 2; }
stage=$1
mode=${2:-}
case $mode in
    ''|--test-data) ;;
    *) echo "usage: scripts/stamp-manifest.sh STAGE [--test-data]" >&2; exit 2 ;;
esac
[ -f "$stage/manifest" ] || { echo "stamp: $stage has no manifest" >&2; exit 1; }
if grep -q '^nx_build=\|^nx_data_ns=' "$stage/manifest"; then
    echo "stamp: $stage/manifest is already stamped" >&2
    exit 1
fi
build=$(cd "$stage" && find . -type f -print0 | LC_ALL=C sort -z | xargs -0 sha1sum | sha1sum | cut -c1-12)
printf 'nx_build=%s\n' "$build" >>"$stage/manifest"
[ "$mode" = --test-data ] && printf 'nx_data_ns=nxtest\n' >>"$stage/manifest"
echo "$build"
