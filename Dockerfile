# syntax=docker/dockerfile:1
# check=skip=SecretsUsedInArgOrEnv
#
# Nostalgex self-hosted web tuner: the same web-tuner.html and plex-tuner.html as
# nostalgex.app, served as static files by nginx on plain http, port 8080.
# See "Run it on your server" in README.md.
#
#   docker build -t nostalgex .
#   docker run -d -p 8080:8080 nostalgex

# The build output is plain HTML, JS and fonts, the same on every architecture, so
# it is built once on the build machine's own platform, never under emulation.
FROM --platform=$BUILDPLATFORM node:22-alpine AS build
WORKDIR /src
COPY package.json package-lock.json ./
RUN npm ci --no-audit --no-fund
COPY . .

# The version Settings shows. Empty means package.json "tunerVersion"; the release
# workflow passes the tag's version, and checks that the two agree.
ARG NOSTALGEX_TUNER_VERSION=
# The shared TMDB/OMDb metadata cache the Apple TV app also reads. The anon key is
# public by design (row level security protects the table) and ends up in the page
# either way. Left empty, enrichment is off in the image.
ARG VITE_SUPABASE_URL=
ARG VITE_SUPABASE_ANON_KEY=
RUN NOSTALGEX_TUNER_VERSION="$NOSTALGEX_TUNER_VERSION" \
    VITE_SUPABASE_URL="$VITE_SUPABASE_URL" \
    VITE_SUPABASE_ANON_KEY="$VITE_SUPABASE_ANON_KEY" \
    npm run build:selfhost

# The stable nginx line. The plan's 1.27 tag stopped getting rebuilds in mid 2025.
FROM nginxinc/nginx-unprivileged:1.30-alpine

# Empty in a local build; docker/40-config.sh then reads the version the build wrote.
ARG NOSTALGEX_TUNER_VERSION=
ENV NOSTALGEX_TUNER_VERSION=$NOSTALGEX_TUNER_VERSION \
    NOSTALGEX_ENRICHMENT=on

LABEL org.opencontainers.image.title="Nostalgex web tuner" \
      org.opencontainers.image.description="Retro TV channel guide for your own Plex, Jellyfin or Emby server, in any browser on your network" \
      org.opencontainers.image.source="https://github.com/chadMueller/Nostalgex" \
      org.opencontainers.image.licenses="MIT" \
      org.opencontainers.image.version="$NOSTALGEX_TUNER_VERSION"

COPY docker/nginx.conf /etc/nginx/conf.d/default.conf
COPY --chmod=0755 docker/40-config.sh /docker-entrypoint.d/40-config.sh
COPY --from=build /src/dist-selfhost /usr/share/nginx/html

# Where the shared lineup is kept (docker/40-config.sh): one small file. Mount a volume on
# /data to keep it across a recreated container; a named volume starts out owned by 101 like
# this folder, a bind mount has to be made writable for uid 101 on the host. Not a VOLUME
# line: nobody gets an anonymous volume they did not ask for.
USER root
RUN mkdir -p /data && chown 101:101 /data
# Runs as the image's unprivileged nginx user (uid 101). Works with a read-only
# root filesystem as long as /tmp is writable (see the compose example).
USER 101
EXPOSE 8080
HEALTHCHECK --interval=30s --timeout=3s --start-period=5s --retries=3 \
  CMD wget -q -O /dev/null http://127.0.0.1:8080/healthz || exit 1
