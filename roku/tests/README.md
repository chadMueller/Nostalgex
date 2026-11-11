# Roku tests

| What | How | Where it runs |
|---|---|---|
| The golden vectors and every suite, off-device | `tests/run.sh` | the RokuCommunity `brs` interpreter; CI |
| The same suites on a TV | `scripts/deploy.sh --test` | every TV in `ROKU_HOSTS`; the one that counts |
| The mechanical review checks on a branch | `tests/pr-check.sh REF` | this Mac or CI |

`run.sh` and `deploy.sh --test` are described in [../README.md](../README.md#tests). This page is about `pr-check.sh`.

## Checking a branch

`tests/pr-check.sh REF` runs, on a throwaway copy of REF, the checks a reviewer would otherwise redo by hand, and prints one line per check:

```
pr-check f4d9f9e (f4d9f9e) against 9ff822b
PASS    testlists  34 test files, each listed once in deploy.sh and run.sh, each reached from main.brs
PASS    includes   every Nx function a component calls is in a script it includes
FAIL    uninit     1 problem(s)
          FAIL components/SettingsView.brs(396): drawRow() reads isOn in a condition before assigning it on this path
...
RESULT  FAIL: 1 failed, 0 to read, 1 not run
```

`PASS` and `FAIL` are what they say. `WARN` is a line for a person to read, not a failure. `NOT RUN` says the check couldn't run here. The exit status is 1 when any check fails. A copy of REF is made with `git worktree` and removed afterwards, so your checkout is never touched.

```sh
tests/pr-check.sh roku/playback-report                 # a branch, against origin/main
tests/pr-check.sh roku/rc-1.0.6 --base 9ff822b \
    --prs 103,104,106,107,108,109,111,112,113,114 \
    --held 105                                          # a release candidate
tests/pr-check.sh roku/rc-1.0.6 --since f4d9f9e        # what changed since the last head that passed
tests/pr-check.sh REF --no-suite                        # the fast checks only (a few seconds)
```

Options: `--base REF` (default `origin/main`; use the main the branch was built on for a candidate), `--since SHA`, `--prs`, `--heads`, `--held`, `--no-suite`, `--no-sca`, `--here` (check this checkout, as CI does), `--summary FILE`, `--log DIR`.

### The checks

| Check | Proves | Doesn't prove |
|---|---|---|
| `testlists` | every `tests/*Tests.brs` is in the `deploy.sh` and `run.sh` lists exactly once and reachable from `main.brs`, nothing listed or called twice | the suites pass |
| `includes` | every `Nx` function a component calls is in a script it includes | the call is right |
| `uninit` | no `if`, `else if` or `while` condition reads a name its branch never assigned (the Settings crash, 2026-10-27) | every uninitialized read; it checks conditions only |
| `dupkeys` | no associative-array literal names a key twice (what keeping both sides of a conflict makes) | the right value was kept |
| `guards` | no secret in a `print`, saved data only through `NxRegSection` and `NxCacheRoot`, no variable named `m` or `run` | |
| `package` | the staged channel has nothing from `tests/` or this tooling | |
| `trailers` | no AI co-author or "Generated with" line in a commit message; commits by `tydude001` or `Owen Voke` (the Android TV port, #151, squash-merged with a hand-written message) are counted and left as they are. The allowance is keyed on the commit's author name (`NX_TRAILER_OK` changes who), not the email or the GitHub account, so a commit that only mentions one of them doesn't get it | |
| `secrets` | no token, key, JWT, Supabase project address, private key, `.env`, `Secrets.xcconfig` or `.pkg` in what the change adds; a plain `NAME = value` assignment is a warning | a secret in an unusual shape |
| `addresses` | no address from the deny list (the hosts in `roku/.env`, which is git-ignored, and `NX_PRCHECK_DENY`; none is written in the repo) or `plex.direct` machine id; other IPv4 addresses are a warning | |
| `dashes` | no em or en dash in a commit message or an added line of a text file | |
| `heads`, `held` | with `--prs` or `--heads`, every PR head is in REF; with `--held`, those heads are not | |
| `sca` | Roku's static analysis finds no errors or warnings | the three dashboard items about the listing's account setting (not code) |
| `suite` | `tests/run.sh` ends with ALL TESTS PASSED | anything on a TV |

`trailers`, `secrets`, `addresses` and `dashes` read the commits in `BASE..REF` that are not already on `origin/main` (`NX_PRCHECK_PUBLIC` changes that), and the lines REF would add to BASE: the diff from BASE to the tree `git merge-tree` makes by merging REF into it. Lines main already has aren't counted again, however many merge bases the two have (a candidate rebuilt over merged PRs has one per PR). Public history isn't under review and can't be rewritten: three blog commits on main (`905bf0e`, `77a5701`, `693b856`) carry a Cursor Agent co-author line, and a range that included them would fail `trailers` every time. When there is nothing to scan, a `range` row warns, because a pass on nothing proves nothing.

`run.sh` runs `testlists` and `dupkeys` too, so they also run on a push to main.

Static analysis runs when `java` (Temurin 21) is on the path and Roku's `sca-cmd.jar` is in `$SCA_DIR/tool/sca-cmd/lib/` (`SCA_DIR` defaults to `~/.cache/roku-sca`, as for `scripts/sca.sh`; fetched on first use; `NX_JAVA` and `NX_SCA_JAR` point at others). With only `podman` it runs `scripts/sca.sh`. With neither it says `NOT RUN`.

### What stays manual

Anything on a TV: `scripts/deploy.sh --test`, scrolling Settings to CHANNEL PACKAGES and back, a plain-deploy smoke test, playback. Also reading the change itself, the privacy wording, and whether a conflict kept the intended side. The checks above only catch mistakes that leave a signature.

### CI

On a pull request the `roku` job in `.github/workflows/ci.yml` runs `tests/pr-check.sh --here` against the PR's base, which includes the suite, and writes the table to the job summary. On a push to main it runs `tests/run.sh` as before.
