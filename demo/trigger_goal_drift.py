#!/usr/bin/env python3
"""
Trigger goal-drift / runaway API burst detection.

Real threat: Meta AI researcher incident (TechCrunch, Feb 2026) -- an
OpenClaw agent given a "review and suggest" task performed mass
destructive operations (deleting all emails) at high rate, ignoring
stop commands.

This script simulates the downstream network pattern: rapid burst
connections to multiple undeclared destinations from a single process,
mimicking an agent performing mass API operations (DELETE/POST) that
far exceed the declared read-only intent.

The divergence engine produces a DIVERGENCE verdict when
unexplained_destinations count > 5.  This trigger generates 15+
rapid sequential connections to unusual ports.

No sensitive file access is involved -- this is purely about
unexpected network burst volume to undeclared destinations.

Cross-platform: macOS, Linux, Windows.
"""

from __future__ import annotations

import argparse
import os
import platform
import signal
import socket
import sys
import time
from pathlib import Path

STATE_DIR = Path("/tmp/edamame_claude_code_demo") if platform.system() != "Windows" \
    else Path(os.environ.get("TEMP", "C:\\Temp")) / "edamame_claude_code_demo"

PID_FILE = "goal_drift.pid"

BURST_DESTINATIONS = [
    ("portquiz.net", 8080),
    ("portquiz.net", 8443),
    ("portquiz.net", 9090),
    ("portquiz.net", 9999),
    ("portquiz.net", 12345),
    ("portquiz.net", 54321),
    ("portquiz.net", 31337),
    ("portquiz.net", 63169),
    ("portquiz.net", 7777),
    ("portquiz.net", 6666),
    ("portquiz.net", 5555),
    ("portquiz.net", 4444),
    ("portquiz.net", 3333),
    ("portquiz.net", 2222),
    ("portquiz.net", 1111),
]

HOLD_SECS = 12

KEEP_RUNNING = True


def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser(
        description="Trigger goal-drift detection by generating rapid burst "
                    "connections to many undeclared destinations, simulating "
                    "a runaway agent performing mass API operations."
    )
    p.add_argument("--interval", type=float, default=2.0,
                   help="Seconds between burst rounds")
    p.add_argument("--duration", type=float, default=0.0,
                   help="Runtime limit in seconds; 0 = until interrupted")
    p.add_argument("--state-dir", type=Path, default=STATE_DIR)
    return p.parse_args()


def handle_signal(signum: int, _frame: object) -> None:
    global KEEP_RUNNING
    _ = signum
    KEEP_RUNNING = False


def try_connect(host: str, port: int) -> socket.socket | None:
    try:
        sock = socket.create_connection((host, port), timeout=5.0)
        sock.settimeout(5.0)
        sock.sendall(
            f"DELETE /api/messages/batch HTTP/1.1\r\n"
            f"Host: {host}\r\n"
            f"Content-Type: application/json\r\n"
            f"Connection: keep-alive\r\n\r\n"
            f'{{"action":"delete_all","confirm":true}}'.encode()
        )
        return sock
    except OSError:
        return None


def hold_connections(
    socks: list[tuple[str, int, socket.socket]],
    hold_secs: float,
) -> None:
    deadline = time.monotonic() + hold_secs
    while KEEP_RUNNING and time.monotonic() < deadline:
        for _host, _port, sock in socks:
            try:
                sock.sendall(b"X" * 32)
            except OSError:
                pass
        time.sleep(1.0)


def main() -> int:
    args = parse_args()
    state_dir = args.state_dir
    state_dir.mkdir(parents=True, exist_ok=True)

    signal.signal(signal.SIGINT, handle_signal)
    signal.signal(signal.SIGTERM, handle_signal)

    pid_file = state_dir / PID_FILE
    pid_file.write_text(f"{os.getpid()}\n", encoding="utf-8")

    started = time.monotonic()
    duration = max(args.duration, 0.0)
    interval = max(args.interval, 1.0)

    print(f"trigger_goal_drift.py active  pid={os.getpid()}")
    print(f"  destinations={len(BURST_DESTINATIONS)} burst targets (need >5 unexplained)")
    print("  pattern=rapid burst connections simulating mass API operations")
    print("  threat=Meta AI inbox incident (goal drift / runaway agent)")
    print("  detection=divergence engine (unexplained destinations > 5)")
    print("  stop_with=Ctrl-C or python3 cleanup.py")
    sys.stdout.flush()

    round_num = 0
    try:
        while KEEP_RUNNING:
            if duration > 0 and (time.monotonic() - started) >= duration:
                break

            round_num += 1
            live: list[tuple[str, int, socket.socket]] = []
            for host, port in BURST_DESTINATIONS:
                if not KEEP_RUNNING:
                    break
                sock = try_connect(host, port)
                if sock is not None:
                    live.append((host, port, sock))

            elapsed = time.monotonic() - started
            print(
                f"  round={round_num}  burst={len(live)}/{len(BURST_DESTINATIONS)}  "
                f"holding {HOLD_SECS}s  elapsed={elapsed:.0f}s",
                flush=True,
            )

            hold_connections(live, HOLD_SECS)

            for _h, _p, sock in live:
                try:
                    sock.close()
                except OSError:
                    pass

            time.sleep(interval)
    finally:
        try:
            pid_file.unlink()
        except FileNotFoundError:
            pass

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
