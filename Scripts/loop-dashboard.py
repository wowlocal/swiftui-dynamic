#!/usr/bin/env python3
"""Live health dashboard for the lane-foodtruck ralph loop.

Collects everything the loop's health actually depends on -- process liveness,
iteration cadence, landing rate, the R2 pixel-debt board and its history, the
anti-drift ratchets, gate activity and disk -- and serves it as JSON beside a
self-contained HTML page.

    Scripts/loop-dashboard.py --once     print one JSON snapshot and exit
    Scripts/loop-dashboard.py            serve on http://127.0.0.1:8787

Every series is derived from a source of truth the loop itself uses, never from
a hand-maintained side file: iteration timings come from the runner's own log
files, the board from Scripts/icecubes-r2.sh at each sha that touched it, the
ratchets from the same file selection Scripts/validate-anti-drift.sh commits.

The expensive series (per-sha git measurements, ~0.1s each) are cached in
/tmp/lane-foodtruck-loop/dashboard-cache.json keyed by sha, so a poll costs one
cheap pass plus whatever landed since the last one.
"""

import calendar
import errno
import json
import re
import shutil
import subprocess
import sys
import time
import urllib.request
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
LOG_DIR = Path("/tmp/lane-foodtruck-loop")
CACHE = LOG_DIR / "dashboard-cache.json"
RUNNER = REPO / ".claude" / "run-foodtruck-loop.sh"
BOARD = REPO / "Scripts" / "icecubes-r2.sh"
RATCHET = REPO / "Scripts" / "validate-anti-drift.sh"
CLAIMS = REPO / ".claude" / "claims.md"

# An iteration shorter than this produced no work: it spun observing a gate an
# earlier iteration had started and still holds the exclusive lock. Measured
# repeatedly at 3-6 minutes; real iterations run 25 minutes to 3 hours.
SPIN_SECONDS = 10 * 60
ANTI_DRIFT_POINTS = 60          # landings deep the ratchet series goes
BOARD_POINTS = 120              # commits deep the board history goes


def run(args, cwd=REPO, timeout=60):
    try:
        out = subprocess.run(
            args, cwd=str(cwd), capture_output=True, text=True, timeout=timeout
        )
        return out.stdout
    except (subprocess.SubprocessError, OSError):
        return ""


def git(*args, **kw):
    return run(["git", *args], **kw)


def load_cache():
    try:
        return json.loads(CACHE.read_text())
    except (OSError, ValueError):
        return {}


def save_cache(cache):
    try:
        LOG_DIR.mkdir(parents=True, exist_ok=True)
        CACHE.write_text(json.dumps(cache))
    except OSError:
        pass


# ── loop process ──────────────────────────────────────────────────────────────

def pids_matching(pattern):
    out = run(["/usr/bin/pgrep", "-f", pattern])
    return [int(p) for p in out.split() if p.isdigit()]


def elapsed_seconds(pid):
    """macOS ps has no `etimes` -- asking for it prints the whole keyword list
    instead of failing, which is how this silently returned nothing at first.
    Parse the formatted `etime` ([[dd-]hh:]mm:ss) instead."""
    raw = run(["/bin/ps", "-o", "etime=", "-p", str(pid)]).strip()
    if not raw or " " in raw:
        return None
    days, _, clock = raw.rpartition("-")
    parts = [int(p) for p in clock.split(":") if p.isdigit()]
    if not parts:
        return None
    seconds = 0
    for part in parts:
        seconds = seconds * 60 + part
    if days.isdigit():
        seconds += int(days) * 86400
    return seconds


def collect_loop():
    runner_pids = pids_matching("run-foodtruck-loop.sh")
    # The runner's claude child is the iteration. Walk the chain (login shell ->
    # pipeline zsh -> runner -> claude) rather than assuming a depth, and skip
    # the short-lived helpers the runner spawns between iterations.
    claude_pid, claude_seconds = None, None
    for pid in sorted(runner_pids, reverse=True):
        for child in run(["/usr/bin/pgrep", "-P", str(pid)]).split():
            seconds = elapsed_seconds(child)
            if seconds is not None and seconds > 30:
                claude_pid, claude_seconds = int(child), seconds
                break
        if claude_pid:
            break
    return {
        "alive": bool(runner_pids),
        "runnerPids": runner_pids,
        "iterationPid": claude_pid,
        "iterationSeconds": claude_seconds,
        "stopFlagSet": (LOG_DIR / "stop").exists(),
        "reaperWired": "reap-gate-scratch" in _read(RUNNER),
    }


def _read(path):
    try:
        return Path(path).read_text(errors="replace")
    except OSError:
        return ""


# ── iterations ────────────────────────────────────────────────────────────────

STAMP = re.compile(r"iter-(\d{8}T\d{6})Z\.log$")
EXIT_LINE = re.compile(r"=== iteration (\d+) exit=(\d+) log=(\S+) ===")


def collect_iterations():
    """Start time comes from the log's own name, end time from its mtime -- the
    runner prints no end stamp, and the file stops growing when claude exits."""
    exits = {}
    for match in EXIT_LINE.finditer(_read(LOG_DIR / "runner.log")):
        exits[match.group(3)] = int(match.group(2))

    rows = []
    for log in sorted(LOG_DIR.glob("iter-*.log")):
        stamp = STAMP.search(log.name)
        if not stamp:
            continue
        # The runner stamps UTC; timegm reads the struct as UTC. (mktime would
        # read it as local and need a correction that daylight saving breaks.)
        started = calendar.timegm(time.strptime(stamp.group(1) + "Z", "%Y%m%dT%H%M%SZ"))
        try:
            ended = log.stat().st_mtime
            size = log.stat().st_size
        except OSError:
            continue
        seconds = max(0, int(ended - started))
        finished = str(log) in exits
        rows.append({
            "startedAt": int(started),
            "seconds": seconds,
            "exit": exits.get(str(log)),
            "running": not finished and size == 0,
            "kind": "spin" if finished and seconds < SPIN_SECONDS else "work",
        })
    rows.sort(key=lambda r: r["startedAt"])
    return rows


# ── landings ──────────────────────────────────────────────────────────────────

def collect_landings(limit=400):
    out = git("log", f"-{limit}", "--format=%H%x1f%ct%x1f%s", "origin/main")
    rows = []
    for line in out.strip().splitlines():
        parts = line.split("\x1f")
        if len(parts) == 3:
            rows.append({"sha": parts[0], "ts": int(parts[1]), "subject": parts[2]})
    rows.reverse()
    return rows


# ── the R2 board and its history ──────────────────────────────────────────────

FLOOR_LINE = re.compile(r"^\s{2,}([a-z][a-z0-9-]*)\s+(\d+)\s*$")


def parse_floors(source):
    """Read the R2_FLOORS block. Comment lines inside it narrate what each drop
    was; they must not be mistaken for screens."""
    screens, inside = {}, False
    for line in source.splitlines():
        if line.startswith("R2_FLOORS=("):
            inside = True
            continue
        if inside:
            if line.startswith(")"):
                break
            if line.lstrip().startswith("#"):
                continue
            match = FLOOR_LINE.match(line)
            if match:
                screens[match.group(1)] = int(match.group(2))
    return screens


def collect_board_history(cache):
    shas = git(
        "log", f"-{BOARD_POINTS}", "--format=%H%x1f%ct", "origin/main", "--",
        "Scripts/icecubes-r2.sh",
    ).strip().splitlines()
    store = cache.setdefault("board", {})
    rows = []
    for line in shas:
        parts = line.split("\x1f")
        if len(parts) != 2:
            continue
        sha, ts = parts[0], int(parts[1])
        if sha not in store:
            store[sha] = parse_floors(git("show", f"{sha}:Scripts/icecubes-r2.sh"))
        screens = store[sha]
        if not screens:
            continue
        rows.append({
            "sha": sha[:8], "ts": ts, "screens": screens,
            "total": sum(screens.values()), "count": len(screens),
        })
    rows.reverse()
    return rows


# ── anti-drift ratchets ───────────────────────────────────────────────────────

def parse_thresholds():
    source = _read(RATCHET)
    out = {}
    for name, key in (
        ("FLOOR_LEVERAGE", "leverageFloor"),
        ("CEIL_IDENTITY_DENSITY", "identityDensityCeiling"),
        ("FLOOR_RUNGS", "rungFloor"),
        ("CEIL_PLATFORM_SPECS", "platformSpecsCeiling"),
        ("CEIL_PAYLOAD_CONSTANTS", "payloadCeiling"),
    ):
        match = re.search(rf"^{name}=([0-9.]+)", source, re.M)
        if match:
            out[key] = float(match.group(1))
    return out


def measure_anti_drift(sha):
    """The same file selection Scripts/validate-anti-drift.sh commits -- if the
    two ever disagree the dashboard is lying, so they are kept identical."""
    gen = git("grep", "-c", "", sha, "--",
              "Sources/*/Generated/*.swift", "Sources/*/Generated*.swift")
    generated = sum(int(l.rsplit(":", 1)[1]) for l in gen.splitlines() if ":" in l)
    bgen = git("grep", "-c", "", sha, "--", "Sources/BridgeGen/")
    generator = sum(int(l.rsplit(":", 1)[1]) for l in bgen.splitlines() if ":" in l)
    hits = git("grep", "-oE", 'case "|== "', sha, "--", "Sources/")
    identity = sum(
        1 for line in hits.splitlines()
        if line and not re.search(r":Sources/[^:]*/Generated", line)
    )
    if not generated or not generator:
        return None
    return {
        "generated": generated,
        "generator": generator,
        "leverage": round(generated / generator, 4),
        "identity": identity,
        "identityDensity": round(identity * 1000 / generated, 3),
    }


def collect_anti_drift(landings, cache):
    store = cache.setdefault("antiDrift", {})
    rows = []
    for landing in landings[-ANTI_DRIFT_POINTS:]:
        sha = landing["sha"]
        if sha not in store:
            measured = measure_anti_drift(sha)
            if measured is None:
                continue
            store[sha] = measured
        rows.append({"sha": sha[:8], "ts": landing["ts"], **store[sha]})
    return rows


# ── gates, disk, claims ───────────────────────────────────────────────────────

def collect_gates():
    out = run(["/bin/ps", "-eo", "pid,etimes,command"])
    running = []
    for line in out.splitlines():
        if "gate.sh" in line and "grep" not in line:
            fields = line.split(None, 2)
            if len(fields) == 3 and fields[1].isdigit():
                running.append({"pid": int(fields[0]), "seconds": int(fields[1])})
    return running


def collect_disk():
    free_gib = None
    df = run(["/bin/df", "-g", "/System/Volumes/Data"]).splitlines()
    if len(df) > 1:
        fields = df[-1].split()
        if len(fields) > 3 and fields[3].isdigit():
            free_gib = int(fields[3])
    # Gate scratch has used four naming schemes over the project's life
    # (lane-gate-<sha>, lane-<sha>-gate[.XXXX], lane-<sha>-full-gate.XXXX,
    # lane-<x>-clean-gate.XXXX). Match on "gate" so a fifth is covered too, and
    # so the loop's own log directory (lane-foodtruck-loop) is not counted.
    scratch = [p for p in Path("/private/tmp").glob("lane-*gate*") if p.is_dir()]
    used = 0
    for path in scratch:
        du = run(["/usr/bin/du", "-sk", str(path)], timeout=20).split()
        if du and du[0].isdigit():
            used += int(du[0])
    return {
        "freeGiB": free_gib,
        "scratchDirs": len(scratch),
        "scratchGiB": round(used / 1024 / 1024, 1),
        "total": shutil.disk_usage("/").total // (1024 ** 3),
    }


CLAIM_EVENT = re.compile(
    r"(20\d\d-\d\d-\d\dT[\d:]+Z)\s+(\S+)\s+(MERGE-READY|MERGE-DONE|STALL[A-Z-]*|BLOCKED)"
)


def collect_claims(limit=12):
    events = []
    for match in CLAIM_EVENT.finditer(_read(CLAIMS)):
        events.append({"at": match.group(1), "lane": match.group(2), "kind": match.group(3)})
    return events[-limit:]


# ── snapshot ──────────────────────────────────────────────────────────────────

def collect():
    started = time.time()
    cache = load_cache()
    landings = collect_landings()
    board = collect_board_history(cache)
    anti = collect_anti_drift(landings, cache)
    save_cache(cache)

    head = git("rev-parse", "--short", "origin/main").strip()
    local = git("rev-parse", "--short", "main").strip()
    behind = git("rev-list", "--count", "main..origin/main").strip()

    return {
        "generatedAt": int(started),
        "collectSeconds": round(time.time() - started, 2),
        "loop": collect_loop(),
        "iterations": collect_iterations(),
        "landings": landings,
        "boardHistory": board,
        "board": board[-1]["screens"] if board else {},
        "antiDrift": anti,
        "thresholds": parse_thresholds(),
        "gates": collect_gates(),
        "disk": collect_disk(),
        "claims": collect_claims(),
        "head": {"originMain": head, "localMain": local, "localBehind": int(behind or 0)},
    }


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path.startswith("/data.json"):
            body = json.dumps(collect()).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Cache-Control", "no-store")
        else:
            body = (REPO / "Scripts" / "loop-dashboard.html").read_bytes()
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *args):
        pass


class Server(HTTPServer):
    # Without this a restart within the TIME_WAIT window fails to bind, which
    # reads as "already running" when nothing is.
    allow_reuse_address = True


def dashboard_answers_on(port):
    """Is the thing holding this port our own dashboard, or a stranger?"""
    try:
        with urllib.request.urlopen(
            f"http://127.0.0.1:{port}/data.json", timeout=3
        ) as response:
            return "boardHistory" in json.loads(response.read())
    except Exception:
        return False


def serve(port):
    """Starting a second copy is the most likely way this is ever run twice, so
    say so and hand over the URL instead of a traceback."""
    for candidate in range(port, port + 10):
        try:
            server = Server(("127.0.0.1", candidate), Handler)
        except OSError as exc:
            if exc.errno != errno.EADDRINUSE:
                raise
            if dashboard_answers_on(candidate):
                print(f"loop dashboard is already serving: http://127.0.0.1:{candidate}", flush=True)
                print(f"stop it with: kill $(lsof -t -iTCP:{candidate} -sTCP:LISTEN)", flush=True)
                return
            print(f"port {candidate} is taken by something else, trying {candidate + 1}", flush=True)
            continue
        # flush: under nohup/redirect stdout is block-buffered, so without this
        # the URL never reaches the log file of a server that then runs for days.
        print(f"loop dashboard: http://127.0.0.1:{candidate}", flush=True)
        try:
            server.serve_forever()
        except KeyboardInterrupt:
            pass
        return
    print(f"no free port in {port}..{port + 9}", file=sys.stderr)
    sys.exit(1)


def main():
    if "--once" in sys.argv:
        print(json.dumps(collect(), indent=2))
        return
    port = 8787
    for i, arg in enumerate(sys.argv):
        if arg == "--port" and i + 1 < len(sys.argv):
            port = int(sys.argv[i + 1])
    serve(port)


if __name__ == "__main__":
    main()
