#!/bin/bash
# N-013: start a LAB Emby or Jellyfin in colima/docker, loopback only, with the synthetic films.
#
#   lab-up.sh emby     4.10.1.0  8196 MEDIA_DIR CRED_FILE
#   lab-up.sh jellyfin 12.2.0    8096 MEDIA_DIR CRED_FILE
#
# Needs colima (it is started if it is down) and the output of make-media.sh as MEDIA_DIR.
# CRED_FILE (mode 0600) receives the lab user, a generated password and a token. Nothing
# secret is printed. Before running, check `ps` for xcodebuild and `uptime` (AGENT-RULES).
set -euo pipefail
KIND="${1:?emby|jellyfin}"; TAG="${2:?image tag}"; PORT="${3:?host port}"
MEDIA="${4:?media dir}"; CRED="${5:?cred file}"
HERE="$(cd "$(dirname "$0")" && pwd)"
NAME="n013-$KIND"
case "$KIND" in
  emby)     IMAGE="emby/embyserver:$TAG";    EXTRA=(-e UID=1000 -e GID=100 -e GIDLIST=100) ;;
  jellyfin) IMAGE="jellyfin/jellyfin:$TAG";  EXTRA=() ;;
  *) echo "kind must be emby or jellyfin" >&2; exit 2 ;;
esac

colima status >/dev/null 2>&1 || colima start
# ~/.docker/config.json may name the Docker Desktop credential helper, which is not installed
# here; public images need no login, so talk to colima's socket with an empty client config.
if ! command -v docker-credential-desktop >/dev/null 2>&1; then
  export DOCKER_HOST="unix://$HOME/.colima/default/docker.sock"
  DOCKER_CONFIG="$(mktemp -d)"; export DOCKER_CONFIG
  echo '{"cliPluginsExtraDirs":["/opt/homebrew/lib/docker/cli-plugins"]}' > "$DOCKER_CONFIG/config.json"
fi
docker rm -f "$NAME" >/dev/null 2>&1 || true
docker volume rm -f "$NAME-config" "$NAME-media" >/dev/null 2>&1 || true
docker volume create "$NAME-config" >/dev/null
docker volume create "$NAME-media" >/dev/null
docker pull -q "$IMAGE" >/dev/null
docker run -d --name "$NAME" -p "127.0.0.1:$PORT:8096" \
  -v "$NAME-config:/config" -v "$NAME-media:/media" ${EXTRA[@]+"${EXTRA[@]}"} "$IMAGE" >/dev/null
docker cp "$MEDIA/Movies" "$NAME:/media/"
docker exec -u 0 "$NAME" chmod -R a+rX /media
echo "started $NAME from $IMAGE on 127.0.0.1:$PORT"
python3 -I "$HERE/lab-setup.py" "$KIND" "http://127.0.0.1:$PORT" "$CRED"
