#!/usr/bin/env python3
"""What a change adds that must never reach the public repo. Reads the commits
in BASE..REF that are not already public, and the lines REF would add to BASE,
and prints one result per check:

  Commits: those reachable from REF and not from BASE or from $NX_PRCHECK_PUBLIC
  (default origin/main). History that is already public isn't under review, and
  it can't be rewritten: three blog commits on main carry a Cursor Agent
  co-author line, and a range that includes them would fail every time.
  Lines: the diff from BASE to the tree `git merge-tree` makes by merging REF
  into BASE, so lines main already has aren't counted again, however many merge
  bases (a candidate rebuilt over merged PRs has one per PR) the two have.
  When there is nothing to scan (no new commit, no added line) a `range` result
  warns, since a pass on nothing proves nothing.

  trailers   an AI co-author or "Generated with" line in a commit message.
             Commits by an author in $NX_TRAILER_OK (default: tydude001 and
             Owen Voke, whose own trailers stay as they are) are counted, not
             failed.
  secrets    a token, key, JWT, Supabase project address, private key or
             password in an added line, or a key, .env, Secrets.xcconfig or
             .pkg added as a file. Strong patterns fail; a plain
             NAME = value assignment is a warning to read.
  addresses  a real server address in an added line: an address listed in
             $NX_PRCHECK_DENY (comma separated), any host named in
             roku/.env (or the file $NX_PRCHECK_ENVFILE), or a plex.direct name with a machine id, fails. Any
             other IPv4 address outside the documentation and loopback ranges
             is a warning to read (tests use home-range examples).
  dashes     an em or en dash in a commit message or in an added line of a
             text file (.brs .xml .md .sh .py .mjs .js .html .txt, not data).

Output, one tab-separated line each: RESULT name STATUS summary, then
DETAIL name text for up to 8 lines. STATUS is PASS, WARN or FAIL.

  scan-added.py REPO BASE REF [--allow-author NAME ...]"""
import os, re, subprocess, sys

repo, base, ref = sys.argv[1:4]
allow = [a.lower() for a in os.environ.get("NX_TRAILER_OK", "tydude001,Owen Voke").split(",") if a]
extra_allow = sys.argv[4:]
while extra_allow:
    if extra_allow[0] == "--allow-author" and len(extra_allow) > 1:
        allow.append(extra_allow[1].lower())
        extra_allow = extra_allow[2:]
    else:
        extra_allow = extra_allow[1:]


def git(*args):
    return subprocess.run(["git", "-C", repo, *args], capture_output=True, text=True, errors="replace").stdout


results = []  # (name, status, summary, [details])


def emit(name, bad, warn, summary_pass, summary_fail, details=()):
    status = "FAIL" if bad else ("WARN" if warn else "PASS")
    results.append((name, status, summary_fail if (bad or warn) else summary_pass, list(details)))


# ---- commits -------------------------------------------------------------
public = os.environ.get("NX_PRCHECK_PUBLIC", "origin/main")
have_public = bool(git("rev-parse", "--verify", "--quiet", public + "^{commit}").strip())
total_range = len([x for x in git("rev-list", f"{base}..{ref}").split("\n") if x])
exclude = [f"^{public}"] if have_public else []
log = git("log", "--format=%H%x1f%an%x1f%s%x1f%B%x1e", f"{base}..{ref}", *exclude)
commits = []
for rec in log.split("\x1e"):
    rec = rec.strip("\n")
    if not rec:
        continue
    h, an, subj, body = rec.split("\x1f", 3)
    commits.append((h[:7], an, subj, body))

TRAILER = re.compile(r"^\s*(co-authored-by:|made-with:|generated (with|by)\b|.{0,4}generated with \[?claude)|noreply@anthropic\.com|claude code", re.I | re.M)
tbad, tok = [], 0
for h, an, subj, body in commits:
    if TRAILER.search(body):
        if an.lower() in allow:
            tok += 1
        else:
            tbad.append(f"{h} ({an}) {subj[:60]}")
public_skipped = total_range - len(commits)
summary = f"{len(commits)} commits, none" + (f"; {tok} by {', '.join(allow)} left as they are" if tok else "") + (f"; {public_skipped} already on {public}, not scanned" if public_skipped > 0 else "")
emit("trailers", tbad, False, summary, f"{len(tbad)} commit(s) with an AI trailer" + (f" ({tok} more by an allowed author)" if tok else ""), tbad[:8])

# ---- added lines ---------------------------------------------------------
def merged_tree():
    out = subprocess.run(["git", "-C", repo, "merge-tree", "--write-tree", "--no-messages", base, ref], capture_output=True, text=True, errors="replace")
    first = out.stdout.split("\n")[0].strip()
    return first if re.fullmatch(r"[0-9a-f]{40,64}", first) else None


target = merged_tree() or ref        # older git: the plain two-dot diff of the trees
diff = git("diff", "--unified=0", "--no-color", "--no-ext-diff", "-M", base, target)
added = []  # (file, line number, text)
newfiles = []
cur, ln = None, 0
for raw in diff.split("\n"):
    if raw.startswith("diff --git "):
        cur = None
    elif raw.startswith("+++ "):
        cur = raw[6:] if raw.startswith("+++ b/") else None
    elif raw.startswith("@@"):
        m = re.match(r"@@ -\S+ \+(\d+)", raw)
        ln = int(m.group(1)) if m else 0
    elif raw.startswith("+") and not raw.startswith("+++") and cur:
        added.append((cur, ln, raw[1:]))
        ln += 1
for line in git("diff", "--name-status", "--no-renames", base, target).split("\n"):
    p = line.split("\t")
    if len(p) == 2 and p[0] == "A":
        newfiles.append(p[1])

SKIP_PATH = re.compile(r"(^|/)(package-lock\.json|tests/vectors/|node_modules/)|\.(png|jpe?g|gif|webp|ttf|otf|woff2?|ico|pkg|zip|mp4|mov)$", re.I)
text = [a for a in added if not SKIP_PATH.search(a[0])]

# secrets
STRONG = [
    ("a JWT", re.compile(r"eyJ[A-Za-z0-9_-]{15,}\.[A-Za-z0-9_-]{15,}\.[A-Za-z0-9_-]{10,}")),
    ("a Supabase key", re.compile(r"\bsb_(publishable|secret)_[A-Za-z0-9_-]{10,}")),
    ("a Supabase project address", re.compile(r"https?://[a-z0-9]{20}\.supabase\.co")),
    ("a Plex token", re.compile(r"X-Plex-Token[=:\"' ]+(?!\w*(?:xxx|token|example|your|placeholder))[A-Za-z0-9_-]{18,}", re.I)),
    ("a private key", re.compile(r"-----BEGIN [A-Z ]*PRIVATE KEY-----")),
    ("a bearer token", re.compile(r"Bearer\s+[A-Za-z0-9._-]{25,}")),
    ("a GitHub token", re.compile(r"\b(ghp_[A-Za-z0-9]{30,}|github_pat_[A-Za-z0-9_]{30,})")),
    ("an AWS key", re.compile(r"\bAKIA[0-9A-Z]{16}\b")),
    ("a Google key", re.compile(r"\bAIza[0-9A-Za-z_-]{35}\b")),
    ("a Slack token", re.compile(r"\bxox[baprs]-[A-Za-z0-9-]{10,}")),
    ("a Discord token", re.compile(r"\b[MN][A-Za-z0-9]{23,}\.[\w-]{6}\.[\w-]{27,}")),
]
WEAK = re.compile(r"\b[A-Z_]*(PASSWORD|SECRET|API_?KEY|ACCESS_TOKEN|AUTH_TOKEN)\s*[=:]\s*[\"']?([A-Za-z0-9/+_.-]{10,})", re.I)
PLACEHOLDER = re.compile(r"^(your|example|placeholder|changeme|xxx|\$|<|\.\.\.|dry-run|test|fake|dummy|secret|password)", re.I)
FORBIDDEN_FILE = re.compile(r"(^|/)(\.env|Secrets\.xcconfig|[^/]*\.(pkg|p12|pem|key))$|(^|/)\.env\.[^/]*$")
sbad, swarn = [], []
for f, n, t in text:
    for what, rx in STRONG:
        if rx.search(t):
            sbad.append(f"{f}:{n} looks like {what}")
    m = WEAK.search(t)
    if m and not PLACEHOLDER.match(m.group(2)) and not re.search(r"\$\{?\w|\(|\bNx\w+", m.group(2)):
        swarn.append(f"{f}:{n} sets {m.group(1).lower()} to a literal; read it")
for p in newfiles:
    if FORBIDDEN_FILE.search(p) and not p.endswith(".env.example"):
        sbad.append(f"{p} is added as a file")
emit("secrets", sbad, swarn, f"{len(text)} added lines, nothing found", f"{len(sbad)} to fix, {len(swarn)} to read", (sbad + swarn)[:8])

# addresses
deny = set(x.strip() for x in os.environ.get("NX_PRCHECK_DENY", "").split(",") if x.strip())
for envp in {os.path.join(repo, "roku", ".env"), os.environ.get("NX_PRCHECK_ENVFILE", "")}:
    if envp and os.path.isfile(envp):
        for l in open(envp, errors="replace"):
            m = re.match(r"\s*(ROKU_[A-Z_]*HOSTS?|[A-Z_]*ADDRESS)\s*=\s*(.+)", l)
            if m:
                for v in re.split(r"[\s,]+", m.group(2).strip().strip("\"'")):
                    if v:
                        deny.add(v)
IP = re.compile(r"(?<![\d.])(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})(?![\d.]*\d)(?!\.\d)")
DOC = [(192, 0, 2), (198, 51, 100), (203, 0, 113)]


def boring(o):
    a, b, c, d = o
    return (a == 127 or o == (0, 0, 0, 0) or a == 255 or (a, b, c) in DOC or (a == 169 and b == 254)
            or a == 0 or a >= 224)


abad, awarn = [], []
for f, n, t in text:
    if any(d and d in t for d in deny):
        abad.append(f"{f}:{n} names a real address from the deny list")
        continue
    if re.search(r"\b[0-9-]+\.[a-f0-9]{32}\.plex\.direct", t, re.I):
        abad.append(f"{f}:{n} has a plex.direct name with a machine id")
        continue
    if f.endswith((".json", ".tsv")):
        continue
    for m in IP.finditer(t):
        o = tuple(int(x) for x in m.groups())
        if any(x > 255 for x in o) or boring(o):
            continue
        awarn.append(f"{f}:{n} has {'.'.join(map(str, o))}")
        break
emit("addresses", abad, awarn, "no real address", f"{len(abad)} real, {len(awarn)} other IPv4 to read", (abad + awarn)[:8])

# dashes
DASH = re.compile("[" + chr(0x2013) + chr(0x2014) + "]")  # en and em dash, written as codes so this file has none
TEXT_EXT = (".brs", ".xml", ".md", ".sh", ".py", ".mjs", ".js", ".html", ".txt", ".yml", ".yaml")
dbad = []
for h, an, subj, body in commits:
    if DASH.search(subj + "\n" + body):
        dbad.append(f"commit {h} ({an}): {subj[:60]}")
for f, n, t in text:
    if f.endswith(TEXT_EXT) and "/fixtures/" not in f and DASH.search(t):
        dbad.append(f"{f}:{n}")
emit("dashes", dbad, False, "no em or en dash", f"{len(dbad)} em or en dash(es)", dbad[:8])

if not commits and not added:
    results.insert(0, ("range", "WARN", f"nothing to scan: {ref[:12]} adds no commit and no line over {base[:12]}, so the four rows below prove nothing", []))

for name, status, summary, details in results:
    print(f"RESULT\t{name}\t{status}\t{summary}")
    for d in details:
        print(f"DETAIL\t{name}\t{d}")
