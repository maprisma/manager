#!/usr/bin/python3 -I
"""A fake `qdbus6` for the tests: plays plasmashell's evaluateScript for Maprisma Manager's two
scripts (read: list the Maprisma Icons widgets; write: compare and write one widget's config).
State: $FAKE_PLASMA (JSON list of widgets as the read script prints them). Every script is
appended to $FAKE_PLASMA.log, so tests can check what was sent."""
import json
import os
import re
import sys

state_file = os.environ["FAKE_PLASMA"]
args = sys.argv[1:]
# KWin (Maprisma Tiling's remove): logged, answered like KWin does.
if args[:1] == ["org.kde.KWin"]:
    with open(state_file + ".kwin.log", "a") as log:
        log.write(" ".join(args) + "\n")
    if os.environ.get("FAKE_KWIN_DOWN"):
        print("Error: org.freedesktop.DBus.Error.ServiceUnknown", file=sys.stderr)
        sys.exit(1)
    if args[-2:-1] == ["org.kde.kwin.Scripting.unloadScript"] or args[-1:] == ["org.kde.kwin.Scripting.unloadScript"]:
        print("true")
    sys.exit(0)
if args[:3] != ["org.kde.plasmashell", "/PlasmaShell", "org.kde.PlasmaShell.evaluateScript"] or len(args) != 4:
    print("fake qdbus6: unexpected call", args, file=sys.stderr)
    sys.exit(2)
script = args[3]
with open(state_file + ".log", "a") as log:
    log.write(script + "\n\x00\n")
if os.environ.get("FAKE_PLASMA_DOWN"):
    print("Error: org.freedesktop.DBus.Error.ServiceUnknown", file=sys.stderr)
    sys.exit(1)
with open(state_file) as f:
    widgets = json.load(f)
KEYS = ["zoneLeft", "zoneCenter", "zoneRight", "hidden"]

def describe(w):
    return {k: w.get(k) for k in ["panel", "widget", "screen", "location", "order"] + KEYS}

# Maprisma Icons' remove: every widget taken out of the panels.
if script.startswith("// mm:remove-widgets"):
    ids = json.loads(re.search(r"^var ids = (.*);$", script, re.M).group(1))
    keep = [w for w in widgets if w["widget"] not in ids]
    with open(state_file, "w") as f:
        json.dump(keep, f)
    print("MM:" + json.dumps({"removed": len(widgets) - len(keep)}))
    sys.exit(0)

m = re.search(r"^var want = (.*);$", script, re.M)
if not m:
    print("MM:" + json.dumps([describe(w) for w in widgets]))
    sys.exit(0)
want = json.loads(m.group(1))
expected = json.loads(re.search(r"^var expected = (.*);$", script, re.M).group(1))
wid = int(re.search(r"ws\[j\]\.id !== (\d+)", script).group(1))
# A concurrent change, set up by a test: applied right before the compare.
race = os.environ.get("FAKE_PLASMA_RACE")
result = None
for w in widgets:
    if w["widget"] != wid:
        continue
    if race:
        w.update(json.loads(race))
    now = describe(w)
    if any(now.get(k) != expected.get(k) for k in KEYS):
        now["changed"] = True
        result = now
        break
    for k, v in want.items():
        w[k] = v
    result = describe(w)
    break
with open(state_file, "w") as f:
    json.dump(widgets, f)
print("MM:" + json.dumps(result))
