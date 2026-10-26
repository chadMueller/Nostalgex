#!/bin/bash
# Build, install and sign a Roku release, then download the signed package.
#
#   scripts/release.sh OUT              OUT is the .pkg to write, or a folder to
#                                       write Nostalgex-roku-X.Y.Z-signed.pkg in
#   scripts/release.sh --dry-run OUT    every check and the build, then stop
#                                       before contacting the stick
#
# Steps: refuse unless manifest's version is past the last release; build the
# app zip as scripts/deploy.sh does (stage.sh, enrichment on, nx_build); check
# the stick holds the signing key; install; sign with plugin_package; download
# the .pkg; record it in releases.tsv. Uploading to the Roku dashboard, the
# commit and the roku-vX.Y.Z tag stay manual (RELEASING.md, "Roku release").
#
# Where each value comes from. None of them is ever printed.
#   ROKU_DEV_PASSWORD    .env, the stick's developer (rokudev) password
#   ROKU_SIGN_HOST       .env or the environment, the stick that holds the
#                        signing key; else ROKU_HOSTS if it names one TV
#   ROKU_DEV_ID          .env, the signing key's Dev ID; the stick must match
#   ROKU_SIGN_PASSWORD   the signing key's password: the environment, else
#                        the login Keychain item "Nostalgex Roku signing key"
#                        (account nostalgex-roku), else a prompt. Never from
#                        .env, which this script ignores for it. A dry run
#                        doesn't look for it.
#   Supabase URL + key   ../Nostalgex/Secrets.xcconfig (or the file named by
#                        NOSTALGEX_SECRETS_XCCONFIG), its $() stripped.
set -euo pipefail
cd "$(dirname "$0")/.."

usage() { echo "usage: scripts/release.sh [--dry-run] OUT.pkg|OUT-FOLDER" >&2; exit 2; }
die() { echo "release: $*" >&2; exit 1; }

dry_run=false
out_arg=
for a in "$@"; do
    case "$a" in
        -n|--dry-run) dry_run=true ;;
        -h|--help) usage ;;
        -*) usage ;;
        *) [ -z "$out_arg" ] || usage; out_arg=$a ;;
    esac
done
[ -n "$out_arg" ] || usage

# --- 1. The version must be past the last release ---------------------------
# Each beta or store upload needs a higher version than any before it. The
# record is releases.tsv (this script appends to it) and any roku-v* tags.
field() { sed -n "s/^$1=//p" manifest | tr -d '\r[:space:]'; }
version="$(field major_version).$(field minor_version).$(field build_version)"
[[ $version =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "manifest version '$version' is not major.minor.build"
[ "$(field title)" = Nostalgex ] || die "manifest title is not Nostalgex"

# Prints the larger of two x.y.z versions.
vmax() {
    local IFS=.
    local a=($1) b=($2) i
    for i in 0 1 2; do
        if ((10#${a[i]} > 10#${b[i]})); then echo "$1"; return; fi
        if ((10#${a[i]} < 10#${b[i]})); then echo "$2"; return; fi
    done
    echo "$1"
}
last=0.0.0
if [ -f releases.tsv ]; then
    for v in $(grep -vE '^[[:space:]]*(#|$)' releases.tsv | cut -f1); do
        [[ $v =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] && last=$(vmax "$last" "$v")
    done
fi
if git rev-parse --git-dir >/dev/null 2>&1; then
    for t in $(git tag -l 'roku-v*'); do
        v=${t#roku-v}
        [[ $v =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] && last=$(vmax "$last" "$v")
    done
fi
if [ "$version" = "$last" ] || [ "$(vmax "$version" "$last")" != "$version" ]; then
    die "manifest is $version but $last is already released; bump build_version (or minor/major) in roku/manifest first"
fi
echo "version: $version (last release $last)"

# --- 2. Where the package goes ------------------------------------------------
if [ -d "$out_arg" ]; then
    out="${out_arg%/}/Nostalgex-roku-$version-signed.pkg"
else
    out=$out_arg
fi
case "$out" in *.pkg) ;; *) die "$out does not end in .pkg" ;; esac
[ -d "$(dirname "$out")" ] || die "folder $(dirname "$out") does not exist"
[ ! -e "$out" ] || die "$out already exists; it will not be overwritten"
out="$(cd "$(dirname "$out")" && pwd)/$(basename "$out")"
echo "package: $out"

# --- 3. Settings and secrets --------------------------------------------------
# What the environment says wins over .env; the signing password never comes
# from .env at all.
env_sign_host=${ROKU_SIGN_HOST:-}
env_sign_password=${ROKU_SIGN_PASSWORD:-}
[ -f .env ] || die "no .env; copy .env.example and set ROKU_DEV_PASSWORD"
# shellcheck source=/dev/null
. ./.env
ROKU_SIGN_PASSWORD=$env_sign_password
# Kept from every program this script runs; only curl gets them, on stdin.
export -n ROKU_SIGN_PASSWORD ROKU_DEV_PASSWORD
[ -n "$env_sign_host" ] && ROKU_SIGN_HOST=$env_sign_host
[ -n "${ROKU_DEV_PASSWORD:-}" ] || die "set ROKU_DEV_PASSWORD in .env"
[ -n "${ROKU_DEV_ID:-}" ] || die "set ROKU_DEV_ID in .env to the signing key's Dev ID"
host=${ROKU_SIGN_HOST:-}
if [ -z "$host" ]; then
    read -r -a hosts <<<"${ROKU_HOSTS:-}"
    [ "${#hosts[@]}" -eq 1 ] || die "set ROKU_SIGN_HOST to the stick that holds the signing key (ROKU_HOSTS names ${#hosts[@]} TVs)"
    host=${hosts[0]}
fi
[[ $host =~ ^[A-Za-z0-9.:-]+$ ]] || die "ROKU_SIGN_HOST is not an address"

xcconfig=${NOSTALGEX_SECRETS_XCCONFIG:-../Nostalgex/Secrets.xcconfig}
[ -f "$xcconfig" ] || die "no $xcconfig (Supabase URL and key for enrichment)"
# xcconfig treats // as a comment, so the URL is written https:/$()/... there.
xc() {
    sed -n "s/^[[:space:]]*$1[[:space:]]*=[[:space:]]*//p" "$xcconfig" | head -1 |
        sed 's/\$()//g; s/^"//; s/"[[:space:]]*$//; s/[[:space:]]*$//'
}
supabase_url=$(xc SUPABASE_URL)
supabase_key=$(xc SUPABASE_ANON_KEY)
# The same checks as deploy.sh, so the build is one deploy.sh would make.
[[ $supabase_url =~ ^https://[A-Za-z0-9.-]+/?$ ]] || die "SUPABASE_URL in $xcconfig is not https://<project>.supabase.co"
[[ $supabase_key =~ ^[A-Za-z0-9._-]+$ ]] || die "SUPABASE_ANON_KEY in $xcconfig is missing or malformed"
echo "enrichment: on (Supabase values from $(basename "$xcconfig"))"

# The key's password, when the shell doesn't give it: the login Keychain,
# then a prompt. The item is made trusting no app (security ... -T ""), so
# macOS asks to allow each read and nothing reads it silently; a missing
# item, or a read that isn't allowed, falls back to the prompt.
keychain_service="Nostalgex Roku signing key"
keychain_account=nostalgex-roku
if ! $dry_run && [ -z "$ROKU_SIGN_PASSWORD" ] && command -v security >/dev/null 2>&1; then
    if ROKU_SIGN_PASSWORD=$(security find-generic-password -s "$keychain_service" -a "$keychain_account" -w 2>/dev/null) &&
        [ -n "$ROKU_SIGN_PASSWORD" ]; then
        echo "signing key password: from the login Keychain"
    else
        ROKU_SIGN_PASSWORD=
        echo "signing key password: not read from the login Keychain (no item, or not allowed); asking" >&2
    fi
fi
if ! $dry_run && [ -z "$ROKU_SIGN_PASSWORD" ]; then
    [ -r /dev/tty ] || die "set ROKU_SIGN_PASSWORD, or run from a terminal to be asked for it"
    read -r -s -p "Signing key password: " ROKU_SIGN_PASSWORD </dev/tty ||
        die "set ROKU_SIGN_PASSWORD, or run from a terminal to be asked for it"
    echo >&2
    [ -n "$ROKU_SIGN_PASSWORD" ] || die "no signing key password"
fi

# --- 4. Build: deploy.sh's app build, enrichment on -------------------------
# Keep this in step with scripts/deploy.sh: the same stage, enrichment.json
# and nx_build hash, so a release is the build deploy.sh would install.
stage=out/release-stage
zip=out/nostalgex-roku-release.zip
resp=out/release-response.html
cleanup() { rm -rf "$stage" "$zip" "$resp" out/release-install.html out/release-pkg.part; }
trap cleanup EXIT
cleanup
scripts/stage.sh "$stage"
printf '{"supabaseURL":"%s","anonKey":"%s"}\n' "$supabase_url" "$supabase_key" >"$stage"/data/enrichment.json
# nx_build as deploy.sh stamps it. Never a test build's data space: a release
# keeps the registry and cachefs: names every installed copy already has.
build=$(scripts/stamp-manifest.sh "$stage")
if grep -q '^nx_data_ns=' "$stage"/manifest; then die "the staged manifest has nx_data_ns, a test build's data space; a release must not"; fi
(cd "$stage" && zip -qr ../"$(basename "$zip")" .)
echo "build: $build ($(find "$stage" -type f | wc -l | tr -d ' ') files, $(($(wc -c <"$zip") / 1024)) KB zipped)"

commit=-
if git rev-parse --git-dir >/dev/null 2>&1; then
    commit=$(git rev-parse --short HEAD)
    [ -z "$(git status --porcelain -- . ../channels.json ../channels-memberships.json ../franchises.json)" ] ||
        { commit="$commit-dirty"; echo "warning: uncommitted changes under roku/ or the shared data; the release records $commit" >&2; }
fi

if $dry_run; then
    echo "dry run: stopping before contacting $host. A real run would:"
    echo "  take the key's password from ROKU_SIGN_PASSWORD, the login Keychain"
    echo "    (\"$keychain_service\", account $keychain_account) or a prompt"
    echo "  check $host is in developer mode and holds the key with Dev ID ROKU_DEV_ID"
    echo "  install this build, sign it as Nostalgex/$version, download it to $out"
    echo "  and add $version to releases.tsv"
    exit 0
fi

# --- 5. The stick --------------------------------------------------------------
# Passwords go to curl on its standard input (-K -), never on its command line,
# where any process on this Mac could read them.
cfg_quote() { local v=${1//\\/\\\\}; v=${v//\"/\\\"}; printf '"%s"' "$v"; }
dev_auth() { printf 'user = %s\n' "$(cfg_quote "rokudev:$ROKU_DEV_PASSWORD")"; }

info=$(curl -s -m 10 "http://$host:8060/query/device-info") || die "$host does not answer on 8060; is the stick on?"
tag() { sed -n "s:.*<$1>\(.*\)</$1>.*:\1:p" <<<"$info" | head -1; }
[ "$(tag developer-enabled)" = true ] || die "$host is not in developer mode"
devid=$(tag keyed-developer-id)
[ "$devid" = "$ROKU_DEV_ID" ] || die "$host holds Dev ID '${devid:-none}', not ROKU_DEV_ID; signing there would make a different app (never re-key the stick without a previous .pkg and its password)"

code=$(dev_auth | curl -s -K - --digest -o out/release-install.html -w '%{http_code}' \
    -F mysubmit=Install -F "archive=@$zip" "http://$host/plugin_install")
[ "$code" = 200 ] && grep -qiE 'Install Success|Identical to previous' out/release-install.html ||
    die "install on $host failed (HTTP $code)"
echo "$host: installed"
# The installed app must be this build before it is signed.
sleep 2
installed=$(curl -s -m 5 "http://$host:8060/query/apps" | sed -n 's:.*<app id="dev"[^>]* version="\([^"]*\)".*:\1:p' | head -1)
[ -z "$installed" ] || [ "$installed" = "$version" ] || die "$host runs dev app $installed, not $version"

code=$({ dev_auth; printf 'form-string = %s\n' "$(cfg_quote "passwd=$ROKU_SIGN_PASSWORD")"; } |
    curl -s -K - --digest -o "$resp" -w '%{http_code}' -F mysubmit=Package \
        -F "app_name=Nostalgex/$version" -F "pkg_time=$(date +%s)000" "http://$host/plugin_package")
[ "$code" = 200 ] || die "signing on $host failed (HTTP $code)"
failed=$(grep -oE 'Failed: [^<]*' "$resp" | head -1 || true)
[ -z "$failed" ] || die "the stick refused to sign: ${failed#Failed: }"
pkg=$(grep -oE 'pkgs/+[A-Za-z0-9_.-]+\.pkg' "$resp" | head -1 || true)
[ -n "$pkg" ] || die "the stick's reply names no package"
pkg=pkgs/$(basename "$pkg")
echo "$host: signed $pkg"

code=$(dev_auth | curl -s -K - --digest -o out/release-pkg.part -w '%{http_code}' "http://$host/$pkg")
[ "$code" = 200 ] && [ "$(head -c 4 out/release-pkg.part)" = Roku ] || die "download of $pkg failed (HTTP $code)"
mv out/release-pkg.part "$out"
md5=$(if command -v md5 >/dev/null; then md5 -q "$out"; else md5sum "$out" | cut -d' ' -f1; fi)

[ -f releases.tsv ] || printf '# version\tdate\tmd5 of the signed .pkg\tcommit\n' >releases.tsv
printf '%s\t%s\t%s\t%s\n' "$version" "$(date +%F)" "$md5" "$commit" >>releases.tsv
echo "done: $out ($(($(wc -c <"$out") / 1024)) KB, md5 $md5)"
echo "next: upload it in the Roku developer dashboard, commit roku/manifest and"
echo "      roku/releases.tsv, then: git tag -a roku-v$version -m \"Nostalgex Roku $version\""
