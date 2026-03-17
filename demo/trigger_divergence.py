#!/usr/bin/env python3
"""
Trigger divergence detection by generating network traffic to destinations
that the active behavioral model does not explain.

The divergence engine produces a DIVERGENCE verdict when
unexplained_destinations count > 5.  A destination is "unexplained" when:
  - model.explains_destination(host) is false
  - model.explains_destination(host:port) is false
  - the destination is not local/infrastructure (RFC1918, loopback, link-local)

This script connects to 12 unusual public endpoints on uncommon ports that
no reasonable Claude Code behavioral model would include.

No sensitive file access is involved -- this is purely about unexpected
network egress.  Credential/file exfiltration detection is the domain of
the vulnerability detector, not the divergence engine.

Designed to run under Claude Code's process tree so the sessions pass the
scope_parent_paths filter.

Prerequisites: A behavioral model must be active and non-stale in EDAMAME
for the divergence engine to produce a DIVERGENCE rather than NO_MODEL.

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

PID_FILE = "divergence.pid"

UNUSUAL_DESTINATIONS = [
    ("portquiz.net", 9999),
    ("portquiz.net", 12345),
    ("portquiz.net", 54321),
    ("portquiz.net", 31337),
    ("portquiz.net", 63169),
    ("portquiz.net", 8888),
    ("portquiz.net", 7777),
    ("portquiz.net", 6666),
    ("neverssl.com", 80),
    ("example.com", 80),
    ("httpbin.org", 80),
    ("icanhazip.com", 80),
]

# On non-eBPF platforms flodbadd attributes sockets to PIDs via periodic
# netstat/libproc polling.  Each connection must survive long enough for
# the PID attribution cycle to pick it up.
HOLD_SECS = 15

KEEP_RUNNING = True


def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser(
        description="Trigger divergence detection by generating unexplained "
                    "network destinations from a Claude Code-parented process."
    )
    p.add_argument("--interval", type=float, default=3.0,
                   help="Seconds between connection rounds")
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
            f"GET / HTTP/1.1\r\nHost: {host}\r\nConnection: keep-alive\r\n\r\n".encode()
        )
        return sock
    except OSError:
        return None


def hold_connections(
    socks: list[tuple[str, int, socket.socket]],
    hold_secs: float,
) -> None:
    """Keep sockets alive by sending periodic keepalive bytes."""
    deadline = time.monotonic() + hold_secs
    while KEEP_RUNNING and time.monotonic() < deadline:
        for _host, _port, sock in socks:
            try:
                sock.sendall(b"X" * 16)
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

    print(f"trigger_divergence.py active  pid={os.getpid()}")
    print(f"  destinations={len(UNUSUAL_DESTINATIONS)} unusual targets (need >5 unexplained)")
    print("  detection=unexplained_destinations count > 5")
    print("  stop_with=Ctrl-C or python3 cleanup.py")
    sys.stdout.flush()

    round_num = 0
    try:
        while KEEP_RUNNING:
            if duration > 0 and (time.monotonic() - started) >= duration:
                break

            round_num += 1
            live: list[tuple[str, int, socket.socket]] = []
            for host, port in UNUSUAL_DESTINATIONS:
                if not KEEP_RUNNING:
                    break
                sock = try_connect(host, port)
                if sock is not None:
                    live.append((host, port, sock))

            elapsed = time.monotonic() - started
            print(
                f"  round={round_num}  connected={len(live)}/{len(UNUSUAL_DESTINATIONS)}  "
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
