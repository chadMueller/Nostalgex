#!/bin/bash
# Vercel's Ignored Build Step, run by vercel.json "ignoreCommand" right after
# the clone. Vercel reads the exit code the opposite way from most tools:
#
#   exit 0  SKIP the deploy
#   exit 1  BUILD and deploy
#
# Skips only when something changed since this branch's last successful
# deployment and all of it is under roku/ or android/ (the Roku port and the
# Android TV app, which the site never ships). Everything else builds,
# including anything this cannot prove: a branch's first deployment, a
# previous commit outside Vercel's shallow clone, a redeploy with no new
# commits, or a git error.
#
# The base is VERCEL_GIT_PREVIOUS_SHA (the last successful deployment's commit
# on this branch), not HEAD^. A push of several commits is judged as a whole,
# so a site change pushed together with a later roku-only commit still builds,
# and a skipped push leaves the base where it was for the next one.
base=${VERCEL_GIT_PREVIOUS_SHA:-}
build() { echo "ignore-build: $1; building"; exit 1; }
[ -n "$base" ] || build "no previous deployment on this branch"
git cat-file -e "$base^{commit}" 2>/dev/null || build "previous deployment ${base:0:7} is not in this clone"

git diff --quiet "$base" HEAD -- . ':(exclude)roku' ':(exclude)android'
case $? in
    0) ;;
    1) build "site files changed since ${base:0:7}" ;;
    *) build "git diff failed" ;;
esac
git diff --quiet "$base" HEAD -- roku android
case $? in
    1) echo "ignore-build: only roku/ or android/ changed since ${base:0:7}; skipping the site deploy"; exit 0 ;;
    0) build "nothing changed since ${base:0:7}" ;;
    *) build "git diff failed" ;;
esac
