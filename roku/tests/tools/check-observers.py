#!/usr/bin/env python3
"""An observer callback must not read a field of a node the component clears.

A task or a view held in `m.<name>` is set to invalid when it is let go (leaving a screen, a new task for an
old one). The node's own observer can still fire after that, and `m.<name>.<field>` is then a dot on invalid:
the app stops in the debugger (2026-11-16, WeatherView.onRadar read m.radarTask.result after clearRadar).

Every sub or function registered with ObserveField("...", "handler") in a component is checked: where
`m.<name> = invalid` is assigned anywhere in that file, the handler may read `m.<name>.<field>` only after
a line that tests `m.<name>` against invalid (a guard), or assign it first, or take the event (`sub handler(ev as Object)`,
ev.GetData()) and read nothing from m.<name>. Reads of a node that is never cleared are fine.

  check-observers.py [ROOT]     ROOT is a roku/ directory; default: this one
Exits 1 and lists each handler."""
import glob, os, re, sys

os.chdir(sys.argv[1] if len(sys.argv) > 1 else os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", ".."))
bad = []
for path in sorted(glob.glob("components/*.brs")):
    text = open(path).read()
    lines = text.split("\n")
    cleared = set(re.findall(r"^\s*m\.(\w+)\s*=\s*invalid\b", text, re.M))
    handlers = set(re.findall(r'ObserveField\(\s*"[^"]*"\s*,\s*"(\w+)"', text))
    for name in handlers:
        m = re.search(r"^\s*(?:sub|function)\s+%s\s*\(" % re.escape(name), text, re.M | re.I)
        if not m:
            continue
        start = text[: m.start()].count("\n")
        end = start + 1
        while end < len(lines) and not re.match(r"^\s*end\s+(sub|function)\b", lines[end], re.I):
            end += 1
        guarded = set()
        for i in range(start + 1, end):
            code = re.sub(r'"(?:[^"]|"")*"', '""', lines[i]).split("'")[0]
            for g in re.findall(r"m\.(\w+)\s*(?:<>|=)\s*invalid", code):
                guarded.add(g)
            # Made here: the handler assigns the node before it uses it.
            for g in re.findall(r"^\s*m\.(\w+)\s*=\s*(?!invalid\b)", code):
                guarded.add(g)
            for g in re.findall(r"\bm\.(\w+)\.\w+", code):
                if g in cleared and g not in guarded:
                    bad.append(f"{path}({i + 1}): {name}() reads m.{g}.<field>, and m.{g} is set to invalid elsewhere in the file")
                    guarded.add(g)
if bad:
    print("FAIL an observer callback reads a node the component clears (use the event's GetData, or test m.<name> first):", file=sys.stderr)
    for b in bad:
        print(b, file=sys.stderr)
    sys.exit(1)
