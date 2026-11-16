#!/bin/bash
# The small grep guards over the BrightScript, each one a mistake that passes
# every test and fails on a TV or leaks a secret. tests/run.sh and
# tests/pr-check.sh both run this, so there is one copy.
#
#   check-guards.sh [ROOT]     ROOT is a roku/ directory; default: this one
#
# Prints "FAIL ..." and the offending lines to stderr and exits 1 on the first
# guard that trips.
set -euo pipefail
cd "${1:-$(dirname "$0")/../..}"

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

# Saved data goes through NxRegSection and NxCacheRoot (source/util/Values.brs),
# so a test-data build keeps its own. A registry section or cachefs: path
# opened anywhere else would be shared with the store app again.
direct=$(grep -rnE 'roRegistrySection|"cachefs:' source components --include=*.brs | grep -vE "^source/util/Values\.brs:|^[^:]+:[0-9]+:\s*'" || true)
if [ -n "$direct" ]; then
    echo "FAIL saved data opened outside NxRegSection or NxCacheRoot:" >&2
    echo "$direct" >&2
    exit 1
fi
# SIGN OUT reaches NxCacheRoot on the render thread, where roFileSystem
# isn't available: Values.brs must do without it.
if grep -n 'roFileSystem' source/util/Values.brs | grep -v ":\s*'"; then
    echo "FAIL source/util/Values.brs uses roFileSystem, which the render thread can't create" >&2
    exit 1
fi

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

# `box` names Roku's builtin Box() the same way: a GuideView with a variable
# named box failed to compile on a 43S45 (2026-11-10, #237) after passing
# the interpreter and static analysis.
builtin=$(grep -rnEi '^\s*(for\s+)?box\s*=[^=]|^\s*for\s+each\s+box\s+in\b|[(,]\s*box\s+as\b' source components tests --include=*.brs || true)
if [ -n "$builtin" ]; then
    echo "FAIL a variable named box (Roku's Box()):" >&2
    echo "$builtin" >&2
    exit 1
fi

# An observer reads its answer from the event, never from m.<task>.result: the field is cleared while a
# task still runs (leaving the weather channel did, 2026-11-16) and the late answer stopped the app.
late=$(grep -nE 'm\.[A-Za-z]*Task\.result' components/WeatherView.brs components/SettingsView.brs || true)
if [ -n "$late" ]; then
    echo "FAIL a task's answer read from m.<task>.result, which may be cleared by then (use the event's GetData):" >&2
    echo "$late" >&2
    exit 1
fi

# An roArray has no Insert method (a call stops the app: "Member function not found", 2026-11-16, PREPARING LINEUP
# on a TV): NxWxInsertAt in source/weather/Weather.brs builds the new array.
badcall=$(grep -rnE '\.Insert\(' source components --include=*.brs | grep -vE ":\s*'" || true)
if [ -n "$badcall" ]; then
    echo "FAIL .Insert( is not an roArray method:" >&2
    echo "$badcall" >&2
    exit 1
fi
