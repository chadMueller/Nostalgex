#!/bin/bash
# Copy the channel into DIR in the layout a Roku sideloads: manifest, source/,
# components/, images/, data/, fonts/, videos/, LICENSE and licenses/. Used by scripts/deploy.sh and
# scripts/sca.sh, and by anything else that builds the zip.
#
#   scripts/stage.sh DIR      DIR must be new or empty
#
# data/channels.json, channels-memberships.json and franchises.json are
# symlinks to the Nostalgex repo root, the same files the Apple TV app and the
# web tuner read. They are copied dereferenced: a symlink copied as a link
# would dangle inside DIR, and zip would quietly leave the file out.
set -euo pipefail
[ $# -eq 1 ] || { echo "usage: scripts/stage.sh DIR" >&2; exit 2; }
mkdir -p "$1"
dir=$(cd "$1" && pwd)
[ -z "$(ls -A "$dir")" ] || { echo "stage: $dir is not empty" >&2; exit 1; }
cd "$(dirname "$0")/.."
cp -RL manifest source components "$dir"/
# The MIT notice and the fonts' licences travel with the app (the Channel
# Store needs them). The third-party notices go under licenses/: at the zip's
# root the static analysis calls the file extraneous.
cp LICENSE "$dir"/
mkdir -p "$dir"/licenses
cp THIRD-PARTY-LICENSES.md "$dir"/licenses/THIRD-PARTY-LICENSES.txt
for d in images data fonts videos weather; do [ -d "$d" ] && cp -RL "$d" "$dir"/; done
rm -f "$dir"/data/enrichment.json
# A checkout without symlinks (core.symlinks=false, as on Windows by default)
# leaves each link as a one-line text file holding its target, so check for
# JSON, not just a file.
for f in channels.json channels-memberships.json franchises.json; do
    [ -f "$dir/data/$f" ] && [ ! -L "$dir/data/$f" ] && [ "$(head -c 1 "$dir/data/$f")" = "{" ] ||
        { echo "stage: data/$f is not the repo root's ../$f (missing, or a symlink this checkout did not create)" >&2; exit 1; }
done
