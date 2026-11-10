#!/bin/sh
# Writes the tuner's runtime config from the environment. nginx serves it at
# /config.json (see docker/nginx.conf). Runs from the nginx image's entrypoint,
# as the unprivileged nginx user, before nginx starts.
#
#   NOSTALGEX_ENRICHMENT=on   (default) TMDB/OMDb metadata from the shared cache and
#                             the nostalgex.app relay. Only TMDB and IMDb ids are sent.
#   NOSTALGEX_ENRICHMENT=off  no Supabase or relay requests at all.
#
#   NOSTALGEX_SHARED_SETTINGS=on   (default) the container holds one lineup (which packages
#                             are on, the channel settings, collections, franchises) in the
#                             /data volume, and every browser starts from it. Needs /data to be
#                             writable (mount a volume on it); without that each browser keeps
#                             its own, as before. Never holds a sign-in. off: no shared file.
#
# tunerVersion is what Settings shows as WEB TUNER 1.0.3 · DOCKER. It comes from
# NOSTALGEX_TUNER_VERSION, which the image sets from its build arg (the release tag's
# version), else from the config.json the build wrote next to the pages (package.json
# "tunerVersion"). Neither: an empty string, and Settings shows no version line.
set -eu

raw="${NOSTALGEX_ENRICHMENT:-on}"
case "$(printf '%s' "$raw" | tr '[:upper:]' '[:lower:]')" in
  on|true|1|yes) enrichment=true ;;
  off|false|0|no) enrichment=false ;;
  *)
    # A typo should not quietly send requests someone tried to turn off.
    echo "$0: NOSTALGEX_ENRICHMENT must be on or off, got '$raw'. Treating it as off." >&2
    enrichment=false
    ;;
esac

safe_version() {
  case "$1" in
    ''|*[!A-Za-z0-9._-]*) return 1 ;;
  esac
}

version="${NOSTALGEX_TUNER_VERSION:-}"
if ! safe_version "$version"; then
  version="$(sed -n 's/.*"tunerVersion"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' \
    /usr/share/nginx/html/config.json 2>/dev/null | head -n 1)"
  safe_version "$version" || version=
fi

mkdir -p /tmp/nostalgex
printf '{"tunerVersion":"%s","musicLookups":false,"enrichment":%s}\n' "$version" "$enrichment" \
  > /tmp/nostalgex/config.json

# The shared lineup: one location for one file, written only when it can work. A nginx
# without the WebDAV module (the PUT) would refuse to start on the directive, so it is
# checked here and the location is simply left out.
rm -f /tmp/nostalgex/settings.conf
shared_raw="${NOSTALGEX_SHARED_SETTINGS:-on}"
case "$(printf '%s' "$shared_raw" | tr '[:upper:]' '[:lower:]')" in
  on|true|1|yes) shared=on ;;
  off|false|0|no) shared=off ;;
  *)
    echo "$0: NOSTALGEX_SHARED_SETTINGS must be on or off, got '$shared_raw'. Treating it as off." >&2
    shared=off
    ;;
esac
if [ "$shared" = on ]; then
  if nginx -V 2>&1 | grep -q -- '--with-http_dav_module'; then
    cat > /tmp/nostalgex/settings.conf <<'CONF'
location = /nostalgex-settings.json {
    root /data;
    default_type application/json;
    expires -1;
    add_header X-Nostalgex-Settings "on" always;
    add_header X-Content-Type-Options "nosniff" always;
    dav_methods PUT;
    create_full_put_path off;
    client_max_body_size 256k;
    limit_except GET HEAD PUT { deny all; }
}
CONF
    echo "$0: shared lineup on (/data/nostalgex-settings.json; mount a writable volume on /data to keep it)"
  else
    echo "$0: this nginx has no WebDAV module, so the shared lineup is off; each browser keeps its own" >&2
  fi
fi

label="${version:-(no version)}"
if [ "$enrichment" = true ]; then
  echo "$0: Nostalgex tuner $label, metadata enrichment on (NOSTALGEX_ENRICHMENT=off turns it off)"
else
  echo "$0: Nostalgex tuner $label, metadata enrichment off"
fi
