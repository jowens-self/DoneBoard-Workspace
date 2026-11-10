#!/bin/bash
# Gathers everything there is to know about DoneBoard misbehaving - from this Mac and from a
# paired iPhone - into one folder, and prints what matters from it.
#
#   Tools/diagnose.sh               # into build/diagnostics/<timestamp>
#   Tools/diagnose.sh some/folder
#
# There is deliberately no way to attach a debugger to the phone app from here - CLAUDE.md says
# why. A freeze in progress is already being written down by the app's own watchdog.
#
# Mac: the running app's stacks (`sample`), the app's own Diagnostics folder - event log, freeze,
# crash and system reports - for both the build.sh app and the sandboxed Xcode one, and the
# system's crash and hang reports for it.
#
# iPhone: the Diagnostics folder out of the app's container, and the system's crash logs for
# DoneBoard, which is where an iOS watchdog kill (0x8badf00d) shows up - and the system's reports
# about itself, for a freeze of the whole phone. The phone has to be paired and reachable; it
# doesn't need to be unlocked for either copy.
#
# Nothing here changes anything on either device.
set -uo pipefail
cd "$(dirname "$0")/.."

OUT="${1:-build/diagnostics/$(date +%Y%m%d-%H%M%S)}"
BUNDLE=com.example.doneboard
mkdir -p "$OUT/mac" "$OUT/iphone"
OUT="$(cd "$OUT" && pwd)"

echo "== Mac"
UNSANDBOXED="$HOME/Library/Application Support/DoneBoardWorkspace/Diagnostics"
SANDBOXED="$HOME/Library/Containers/$BUNDLE/Data/Library/Application Support/DoneBoardWorkspace/Diagnostics"
[ -d "$UNSANDBOXED" ] && cp -R "$UNSANDBOXED" "$OUT/mac/Diagnostics" && echo "copied the build.sh app's diagnostics"
[ -d "$SANDBOXED" ] && cp -R "$SANDBOXED" "$OUT/mac/Diagnostics-sandboxed" && echo "copied the Xcode app's diagnostics"

PID="$(pgrep -x DoneBoard | head -1)"
if [ -n "$PID" ]; then
  sample "$PID" 3 -file "$OUT/mac/sample.txt" >/dev/null 2>&1 && echo "sampled the running app (pid $PID) into mac/sample.txt"
fi
find "$HOME/Library/Logs/DiagnosticReports" /Library/Logs/DiagnosticReports -maxdepth 2 \
  -iname 'DoneBoard*' -mtime -14 -exec cp {} "$OUT/mac/" \; 2>/dev/null

echo "== iPhone"
DEVICE="${DEVICE:-}"
if [ -z "$DEVICE" ]; then
  xcrun devicectl list devices --json-output "$OUT/iphone/devices.json" >/dev/null 2>&1
  DEVICE="$(python3 - "$OUT/iphone/devices.json" <<'PY'
import json, sys
try:
    devices = json.load(open(sys.argv[1]))["result"]["devices"]
except Exception:
    devices = []
# The phone itself. devicectl lists simulators too, paired and iOS like it, and a booted one
# came first once - every copy then failed with "Transfer Files is not supported".
for d in devices:
    hardware = d.get("hardwareProperties", {})
    if hardware.get("platform") == "iOS" and hardware.get("reality") == "physical" \
       and d.get("connectionProperties", {}).get("pairingState") == "paired":
        print(d["identifier"])
        break
PY
)"
fi

if [ -z "$DEVICE" ]; then
  echo "no paired iPhone found"
else
  if xcrun devicectl device copy from --device "$DEVICE" --timeout 120 \
       --domain-type appDataContainer --domain-identifier "$BUNDLE" \
       --source "Library/Application Support/DoneBoardWorkspace/Diagnostics" \
       --destination "$OUT/iphone/Diagnostics" >"$OUT/iphone/copy.log" 2>&1; then
    echo "copied the phone app's diagnostics"
  else
    echo "couldn't copy the phone app's diagnostics - see iphone/copy.log"
  fi

  mkdir -p "$OUT/iphone/system"
  if xcrun devicectl device copy from --device "$DEVICE" --timeout 180 \
       --domain-type systemCrashLogs --source / \
       --destination "$OUT/iphone/system" >>"$OUT/iphone/copy.log" 2>&1; then
    find "$OUT/iphone/system" -type f -iname 'DoneBoard*' -exec mv {} "$OUT/iphone/" \;
    echo "copied the phone's crash logs for DoneBoard"
    # A freeze of the whole phone - the power-off slider too, as on 2026-10-27 - is the system's
    # own processes stalling, so it leaves nothing under DoneBoard's name: memory running out
    # (JetsamEvent), the screen's server or SpringBoard hanging, the GPU being restarted, a panic.
    # And a watchdog that ends any process files a stackshot of every process, DoneBoard included,
    # under that process's name - on 2026-10-27 the one trace was filed as ScreenshotServicesService.
    # So: those by name, and anything else from the last three days that lists DoneBoard inside it.
    mkdir -p "$OUT/iphone/whole-phone"
    find "$OUT/iphone/system" -type f -mtime -3 \( -iname 'JetsamEvent*' -o -iname '*backboardd*' \
      -o -iname '*SpringBoard*' -o -iname '*GPU*' -o -iname 'panic*' -o -iname 'stacks*' \
      -o -iname '*Watchdog*' -o -iname 'ResetCounter*' \) -exec mv {} "$OUT/iphone/whole-phone/" \;
    find "$OUT/iphone/system" -type f -name '*.ips' -mtime -3 -print0 \
      | xargs -0 grep -lE '"(procname|name)" *: *"DoneBoard"' 2>/dev/null \
      | while read -r report; do mv "$report" "$OUT/iphone/whole-phone/"; done
    [ -n "$(ls -A "$OUT/iphone/whole-phone")" ] && echo "copied the phone's own reports from the last three days"
  fi
  rm -rf "$OUT/iphone/system"
fi

# backtrace_symbols_fd can't demangle Swift names; the Swift toolchain can.
find "$OUT" -type f \( -name '*.txt' -o -name '*.log' \) | while read -r file; do
  xcrun swift-demangle --compact <"$file" >"$file.demangled" 2>/dev/null && mv "$file.demangled" "$file"
done

echo
echo "== What it says"
python3 - "$OUT" <<'PY'
import glob, json, os, re, sys
out = sys.argv[1]

def system_report(path):
    raw = open(path, errors="replace").read()
    if "\n" not in raw:
        return
    head, body = raw.split("\n", 1)
    try:
        h, b = json.loads(head), json.loads(body)
    except ValueError:
        print(f"  {os.path.basename(path)} (not a JSON report)")
        return
    reasons = " ".join(b.get("termination", {}).get("reasons", []))[:240]
    exc = b.get("exception", {})
    print(f"  {os.path.basename(path)}: {exc.get('type', '')} {exc.get('signal', '')} {reasons}")
    images = b.get("usedImages", [])
    for thread in b.get("threads", []):
        if not thread.get("triggered"):
            continue
        for frame in thread.get("frames", [])[:14]:
            index = frame.get("imageIndex")
            image = images[index].get("name", "?") if index is not None and index < len(images) else "?"
            print(f"      {image:28} {frame.get('symbol', '?')}")

for label in ("mac", "iphone"):
    reports = sorted(glob.glob(f"{out}/{label}/*.ips"))
    if reports:
        print(f"{label}: the system's reports")
        for path in reports[-4:]:
            system_report(path)
    for folder in sorted(glob.glob(f"{out}/{label}/Diagnostics*")):
        logs = [p for p in (f"{folder}/events.1.log", f"{folder}/events.log") if os.path.exists(p)]
        lines = []
        for p in logs:
            lines += open(p, errors="replace").read().splitlines()
        notable = [l for l in lines if re.search(r"\] (main|bg  ) (hang|crash|app  ) |failed|still waiting|can't reach", l)]
        print(f"{label}: {os.path.basename(folder)} - {len(lines)} log lines, recent notable ones:")
        for l in notable[-25:]:
            print("   ", l[:220])
        reports = sorted(os.listdir(f"{folder}/Reports")) if os.path.isdir(f"{folder}/Reports") else []
        if reports:
            print(f"    reports: {', '.join(reports[-8:])}")
def whole_phone(path):
    head, _, body = open(path, errors="replace").read().partition("\n")
    try:
        h, b = json.loads(head), json.loads(body)
    except ValueError:
        print(f"  {os.path.basename(path)}")
        return
    line = f"  {os.path.basename(path)} (bug type {h.get('bug_type', '?')})"
    if b.get("largestProcess"):
        # Routine on a busy phone - the system makes room by ending background processes. It only
        # matters here if DoneBoard was one of them.
        line += f" - memory ran out, largest process {b['largestProcess']}"
        ours = [p for p in b.get("processes", []) if p.get("name") == "DoneBoard"]
        if ours:
            reason = ours[0].get("reason")
            line += f"; DoneBoard ended for it ({reason})" if reason else f"; DoneBoard {', '.join(ours[0].get('states', []))}, left alone"
    if b.get("panicString"):
        line += f" - panic: {b['panicString'][:160]}"
    details = (b.get("termination") or {}).get("details") or []
    if details:
        line += f" - {details[0][:160]}"
    print(line)
    # A stackshot lists every process. Say what DoneBoard was doing when it was taken.
    processes = (b.get("stackshot") or {}).get("processByPid") or {}
    for pid, p in processes.items():
        if p.get("procname") != "DoneBoard":
            continue
        cpu = (p.get("userTimeTask") or 0) + (p.get("systemTimeTask") or 0)
        flags = [f for f in p.get("flags", []) if f in ("foreground", "suspended", "frozen", "darwinBG", "boosted")]
        print(f"      DoneBoard, pid {pid}: {', '.join(flags) or 'running'}, up {p.get('processUptime', '?')}s, "
              f"{cpu:.1f}s of CPU")
        for wait in p.get("waitInfo", [])[:4]:
            print(f"        {wait}")

def stamp(path):
    try:
        return json.loads(open(path, errors="replace").readline()).get("timestamp", "")
    except ValueError:
        return ""

whole = sorted(glob.glob(f"{out}/iphone/whole-phone/*"), key=stamp)
if whole:
    print("iphone: the phone's own reports - where a freeze of the whole phone shows up")
    for path in whole[-12:]:
        whole_phone(path)
print(f"\neverything is in {out}")
PY
