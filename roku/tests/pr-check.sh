#!/bin/bash
# The mechanical checks on a Roku branch, PR or release candidate, in one
# command, so a reviewer reads a short report instead of redoing them by hand.
# Test tooling only: scripts/stage.sh packs manifest, source, components,
# images, data and fonts, so nothing here reaches the channel package (the
# "package" check below proves it each run).
#
#   tests/pr-check.sh REF [options]
#
#   --base REF        what the change is measured against (default origin/main)
#   --since SHA       also list what changed since the last head that passed
#   --prs 103,104     PR numbers whose heads must all be in REF (needs gh)
#   --heads a1b2c3,.. head commits that must all be in REF (PR:sha also works)
#   --held 105,0495b8d  PRs or commits that must NOT be in REF
#   --no-suite        skip the full off-device suite (the slow check)
#   --no-sca          skip static analysis
#   --here            check this checkout as it is, not a throwaway copy of REF
#   --summary FILE    also append the report to FILE as markdown (CI job summary)
#   --log DIR         keep the full logs in DIR (default: a temp dir, printed
#                     when a check fails)
#
# One line per check: PASS, WARN (read it), FAIL, or NOT RUN. The exit status
# is 1 when any check fails, so CI can use it. A tool is always the one in the
# checkout you run this from, applied to REF's tree, so a head from before a
# check existed (4f0a467 and check-uninit.py) is still held to it.
#
# What it proves, and what it can't: see tests/README.md, "Checking a branch".
set -uo pipefail

here=$(cd "$(dirname "$0")/.." && pwd)          # the checker's roku/
repo=$(git -C "$here" rev-parse --show-toplevel)
tools="$here/tests/tools"

usage() { sed -n '2,/^set -uo/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'; exit 2; }
[ $# -ge 1 ] || usage
ref=$1; shift
base=origin/main; since=; prs=; heads=; held=; suite=1; sca=1; here_mode=0; summary=; logdir=
while [ $# -gt 0 ]; do
    case $1 in
        --base) base=${2:?}; shift 2 ;;
        --since) since=${2:?}; shift 2 ;;
        --prs) prs=${2:?}; shift 2 ;;
        --heads) heads=${2:?}; shift 2 ;;
        --held) held=${2:?}; shift 2 ;;
        --no-suite) suite=0; shift ;;
        --no-sca) sca=0; shift ;;
        --here) here_mode=1; shift ;;
        --summary) summary=${2:?}; shift 2 ;;
        --log) logdir=${2:?}; shift 2 ;;
        -h|--help) usage ;;
        *) echo "pr-check: unknown option $1" >&2; usage ;;
    esac
done

sha=$(git -C "$repo" rev-parse --verify --quiet "$ref^{commit}") || { echo "pr-check: no such commit: $ref" >&2; exit 2; }
short=$(git -C "$repo" rev-parse --short "$sha")
git -C "$repo" rev-parse --verify --quiet "$base^{commit}" >/dev/null || { echo "pr-check: no such base: $base (try --base main)" >&2; exit 2; }

work=$(mktemp -d "${TMPDIR:-/tmp}/pr-check.XXXXXX")
[ -n "$logdir" ] && mkdir -p "$logdir" || logdir=$work/logs
mkdir -p "$logdir"
tree=$work/tree
cleanup() {
    [ "$here_mode" = 1 ] || git -C "$repo" worktree remove --force "$tree" >/dev/null 2>&1
    if [ "${failed:-0}" = 0 ]; then rm -rf "$work"; fi
}
trap cleanup EXIT

if [ "$here_mode" = 1 ]; then
    T=$here
else
    git -C "$repo" worktree add -q --detach "$tree" "$sha" || { echo "pr-check: cannot check out $ref" >&2; exit 2; }
    T=$tree/roku
fi
[ -d "$T" ] || { echo "pr-check: $ref has no roku/ directory" >&2; exit 2; }

nfail=0; nwarn=0; nskip=0; failed=0
md=
line() { # STATUS name text [detail lines from stdin]
    local status=$1 name=$2 text=$3 d
    printf '%-8s%-11s%s\n' "$status" "$name" "$text"
    md="$md| $status | $name | $text |
"
    case $status in FAIL) nfail=$((nfail + 1)); failed=1 ;; WARN) nwarn=$((nwarn + 1)) ;; "NOT RUN") nskip=$((nskip + 1)) ;; esac
    if [ "$status" = FAIL ] || [ "$status" = WARN ]; then
        while IFS= read -r d; do [ -n "$d" ] && printf '          %s\n' "$d"; done
    fi
}
# Run a checker that prints FAIL lines and exits 1; $1 name, $2 pass text, rest is the command.
runcheck() {
    local name=$1 ok=$2 out rc; shift 2
    out=$("$@" 2>&1); rc=$?
    if [ $rc = 0 ]; then
        line PASS "$name" "$ok" </dev/null
    else
        local n; n=$(printf '%s\n' "$out" | grep -c '^FAIL')
        [ "$n" -gt 0 ] || n=1
        local shown=""; [ "$n" -gt 8 ] && shown=" (first 8 shown)"
        line FAIL "$name" "$n problem(s)$shown" < <(printf '%s\n' "$out" | head -8)
    fi
}

printf 'pr-check %s (%s) against %s\n' "$ref" "$short" "$base"
git -C "$repo" log -1 --format='  %an: %s' "$sha" | cut -c1-110

# ---- the slow one starts first and runs while the rest are checked ----------
suite_pid=
if [ "$suite" = 1 ]; then
    ( cd "$T" && bash tests/run.sh >"$logdir/suite.log" 2>&1; echo $? >"$logdir/suite.rc" ) &
    suite_pid=$!
fi

# ---- static checks on REF's tree, with this checkout's tools ----------------
ntests=$(ls "$T"/tests/*Tests.brs 2>/dev/null | wc -l | tr -d ' ')
runcheck testlists "$ntests test files, each listed once in deploy.sh and run.sh, each reached from main.brs" python3 "$tools/check-testlists.py" "$T"
runcheck includes "every Nx function a component calls is in a script it includes" python3 "$tools/check-includes.py" "$T"
runcheck uninit "no condition reads a name its branch never assigned" python3 "$tools/check-uninit.py" "$T"
runcheck dupkeys "no associative-array literal repeats a key" python3 "$tools/check-dupkeys.py" "$T"
runcheck observers "no observer callback reads a node its component clears" python3 "$tools/check-observers.py" "$T"
runcheck guards "no secret in a print, saved data only through NxRegSection/NxCacheRoot, no m or run variable" bash "$tools/check-guards.sh" "$T"

# ---- the package carries nothing from tests/ --------------------------------
stage=$work/stage
if bash "$T/scripts/stage.sh" "$stage" >"$logdir/stage.log" 2>&1; then
    leak=$(cd "$stage" && find . -type f | grep -E '(^|/)(tests|pr-check|\.env|[^/]*\.pkg)(/|$)|pr-check|check-(uninit|includes|testlists|dupkeys|guards)|scan-added' | head -5)
    kb=$(du -sk "$stage" | cut -f1)
    if [ -n "$leak" ]; then line FAIL package "test tooling is in the staged channel package" < <(printf '%s\n' "$leak")
    else line PASS package "the staged channel has no tests/ or test tooling ($kb KB unpacked)" </dev/null; fi
else
    line FAIL package "stage.sh failed (see $logdir/stage.log)" < <(tail -3 "$logdir/stage.log")
fi

# ---- what the change adds: trailers, secrets, addresses, dashes -------------
scanout=$(NX_PRCHECK_ENVFILE="$here/.env" python3 "$tools/scan-added.py" "$repo" "$base" "$sha" 2>&1)
if printf '%s\n' "$scanout" | grep -q '^RESULT'; then
    for name in range trailers secrets addresses dashes; do
        row=$(printf '%s\n' "$scanout" | awk -F'\t' -v n="$name" '$1=="RESULT" && $2==n {print $3 "\t" $4}')
        st=${row%%$'\t'*}; txt=${row#*$'\t'}
        if [ -z "$st" ]; then
            [ "$name" = range ] && continue     # only present when there is nothing to scan
            line FAIL "$name" "scan produced no result" </dev/null; continue
        fi
        line "$st" "$name" "$txt" < <(printf '%s\n' "$scanout" | awk -F'\t' -v n="$name" '$1=="DETAIL" && $2==n {print $3}')
    done
else
    line FAIL scan "scan-added.py failed" < <(printf '%s\n' "$scanout" | head -5)
fi

# ---- did every PR head merge? ------------------------------------------------
resolve_one() { # PR number or sha or PR:sha -> "label sha" (sha empty when unknown)
    local x=$1 label sha_
    case $x in
        *:*) label="#${x%%:*}"; sha_=${x#*:} ;;
        *[!0-9]*) label=${x:0:7}; sha_=$x ;;
        *)
            label="#$x"
            sha_=$(gh pr view "$x" --repo "$(git -C "$repo" remote get-url origin 2>/dev/null | sed -E 's#.*github.com[:/]##; s#\.git$##')" --json headRefOid -q .headRefOid 2>/dev/null)
            [ -n "$sha_" ] && ! git -C "$repo" cat-file -e "$sha_^{commit}" 2>/dev/null && git -C "$repo" fetch -q origin "pull/$x/head" 2>/dev/null
            ;;
    esac
    echo "$label $sha_"
}
descr() { case $1 in "#"*) echo "$1 ${2:0:7}" ;; *) echo "${2:0:7}" ;; esac; }
if [ -n "$prs$heads" ]; then
    miss=; n=0; ok=0
    for x in $(echo "$prs,$heads" | tr ',' ' '); do
        set -- $(resolve_one "$x"); label=$1; h=${2:-}
        n=$((n + 1))
        if [ -z "$h" ] || ! git -C "$repo" cat-file -e "$h^{commit}" 2>/dev/null; then
            miss="$miss$label: head unknown here (no gh, or not fetched)
"; continue
        fi
        if git -C "$repo" merge-base --is-ancestor "$h" "$sha"; then ok=$((ok + 1)); else miss="$miss$(descr "$label" "$h") is not in $short
"; fi
    done
    if [ "$ok" = "$n" ]; then line PASS heads "all $n PR heads are in $short" </dev/null
    else line FAIL heads "$ok of $n PR heads are in $short" < <(printf '%s' "$miss"); fi
fi
if [ -n "$held" ]; then
    bad=; n=0
    for x in $(echo "$held" | tr ',' ' '); do
        set -- $(resolve_one "$x"); label=$1; h=${2:-}
        n=$((n + 1))
        [ -n "$h" ] && git -C "$repo" cat-file -e "$h^{commit}" 2>/dev/null || continue
        git -C "$repo" merge-base --is-ancestor "$h" "$sha" && bad="$bad$(descr "$label" "$h") is in $short but was to be held back
"
    done
    if [ -z "$bad" ]; then line PASS held "none of the $n held heads is in $short" </dev/null
    else line FAIL held "a held head is in" < <(printf '%s' "$bad"); fi
fi

# ---- static analysis ---------------------------------------------------------
if [ "$sca" = 1 ]; then
    java=${NX_JAVA:-$(command -v java 2>/dev/null || true)}
    scadir=${SCA_DIR:-$HOME/.cache/roku-sca}     # as scripts/sca.sh: $scadir/tool/sca-cmd/lib/sca-cmd.jar
    jar=${NX_SCA_JAR:-$scadir/tool/sca-cmd/lib/sca-cmd.jar}
    if [ -n "$java" ] && "$java" -version >/dev/null 2>&1; then
        if [ ! -f "$jar" ] && [ -z "${NX_SCA_JAR:-}" ] && [ "${NX_SCA_DOWNLOAD:-1}" = 1 ] && command -v curl >/dev/null && command -v unzip >/dev/null; then
            mkdir -p "$scadir" && curl -sSfL -o "$scadir/sca-cmd.zip" https://devtools.web.roku.com/static-channel-analysis/sca-cmd.zip \
                && rm -rf "$scadir/tool" && mkdir -p "$scadir/tool" && unzip -q "$scadir/sca-cmd.zip" -d "$scadir/tool" 2>/dev/null
        fi
        if [ -f "$jar" ] && [ -d "$stage" ]; then
            ( cd "$stage" && rm -f "$work/app.zip" && zip -qr "$work/app.zip" . )
            "$java" -jar "$jar" "$work/app.zip" --severity info >"$logdir/sca.txt" 2>&1
            errs=$(grep -E '^\[ERROR\]' "$logdir/sca.txt" || true)
            warns=$(grep -E '^\[WARNING\]' "$logdir/sca.txt" || true)
            if [ -n "$errs" ]; then line FAIL sca "static analysis reports errors" < <(printf '%s\n' "$errs" | head -8)
            elif [ -n "$warns" ]; then line WARN sca "static analysis reports warnings" < <(printf '%s\n' "$warns" | head -8)
            else line PASS sca "static analysis: no errors or warnings" </dev/null; fi
        else
            line "NOT RUN" sca "Java is here but Roku's sca-cmd.jar is not (set NX_SCA_JAR, or let scripts/sca.sh fetch it)" </dev/null
        fi
    elif command -v podman >/dev/null 2>&1; then
        if ( cd "$T" && bash scripts/sca.sh >"$logdir/sca.txt" 2>&1 ); then line PASS sca "scripts/sca.sh: no errors" </dev/null
        else line FAIL sca "scripts/sca.sh failed" < <(grep -E '^\[(ERROR|WARNING)\]' "$logdir/sca.txt" | head -8); fi
    else
        line "NOT RUN" sca "no Java 21 and no podman here, so scripts/sca.sh can't run" </dev/null
    fi
fi

# ---- the suite ---------------------------------------------------------------
if [ "$suite" = 1 ]; then
    wait "$suite_pid" 2>/dev/null
    rc=$(cat "$logdir/suite.rc" 2>/dev/null || echo 1)
    if [ "$rc" = 0 ] && tail -3 "$logdir/suite.log" | grep -qx 'ALL TESTS PASSED'; then
        line PASS suite "tests/run.sh: ALL TESTS PASSED" </dev/null
    else
        line FAIL suite "tests/run.sh did not pass (log: $logdir/suite.log)" < <(grep -E '^(FAIL|TESTS FAILED)|[1-9][0-9]* failed' "$logdir/suite.log" | head -6)
    fi
else
    line "NOT RUN" suite "--no-suite" </dev/null
fi

# ---- since the last passed head ----------------------------------------------
if [ -n "$since" ]; then
    if git -C "$repo" cat-file -e "$since^{commit}" 2>/dev/null; then
        echo "since $(git -C "$repo" rev-parse --short "$since"):"
        n=$(git -C "$repo" rev-list --count "$since..$sha")
        files=$(git -C "$repo" diff --name-only "$since" "$sha" -- roku channels.json channels-memberships.json franchises.json)
        if [ -z "$files" ]; then
            echo "  roku/ and the shared data are identical to $since: nothing to re-run"
        else
            app=$(printf '%s\n' "$files" | grep -E '^(roku/(source|components|manifest|images|data|fonts)|channels\.json|channels-memberships\.json|franchises\.json)' || true)
            tst=$(printf '%s\n' "$files" | grep -E '^roku/(tests|scripts)/' || true)
            doc=$(printf '%s\n' "$files" | grep -vE '^(roku/(source|components|manifest|images|data|fonts|tests|scripts)|channels\.json|channels-memberships\.json|franchises\.json)' || true)
            echo "  $n commit(s), $(printf '%s\n' "$files" | wc -l | tr -d ' ') file(s): $(printf '%s' "$app" | grep -c .) app, $(printf '%s' "$tst" | grep -c .) test or script, $(printf '%s' "$doc" | grep -c .) docs"
            if [ -n "$app" ]; then
                echo "  app files changed, so a device pass on these is due again:"
                printf '%s\n' "$app" | head -20 | sed 's/^/    /'
            else
                echo "  no app file changed: a device re-run is not needed, only the checks above"
            fi
            git -C "$repo" log --format='    %h %s' "$since..$sha" | head -12 | cut -c1-110
        fi
    else
        echo "since: $since is not a commit here"
    fi
fi

verdict=PASS
[ "$nwarn" -gt 0 ] && verdict=PASS-with-warnings
[ "$nfail" -gt 0 ] && verdict=FAIL
printf 'RESULT  %s: %d failed, %d to read, %d not run\n' "$verdict" "$nfail" "$nwarn" "$nskip"
[ "$failed" = 1 ] && echo "logs: $logdir"

if [ -n "$summary" ]; then
    {
        echo "### pr-check $short against $base: $verdict"
        echo
        echo "| Result | Check | What |"
        echo "|---|---|---|"
        printf '%s' "$md"
        echo
    } >>"$summary"
fi
[ "$nfail" -eq 0 ]
