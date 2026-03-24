#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: bash setup/install.sh [workspace_root]

Installs the Claude Code EDAMAME package for the target workspace.
Behavioral-model refresh is driven by Claude Code's stdio MCP lifecycle --
the bridge refreshes on initialization and tool calls.
EOF
}

WORKSPACE_ROOT=""

while (($# > 0)); do
  case "$1" in
    -h|--help)
      usage
      exit 0
      ;;
    -*)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 1
      ;;
    *)
      if [[ -n "$WORKSPACE_ROOT" ]]; then
        echo "Unexpected extra argument: $1" >&2
        usage >&2
        exit 1
      fi
      WORKSPACE_ROOT="$1"
      ;;
  esac
  shift
done

SOURCE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORKSPACE_ROOT="${WORKSPACE_ROOT:-$PWD}"

OS_KERNEL="$(uname -s)"
case "$OS_KERNEL" in
  Darwin)
    CONFIG_HOME="$HOME/Library/Application Support/claude-code-edamame"
    STATE_HOME="$CONFIG_HOME/state"
    DATA_HOME="$HOME/Library/Application Support/claude-code-edamame"
    ;;
  MINGW*|MSYS*|CYGWIN*)
    CONFIG_HOME="${APPDATA:-$HOME/AppData/Roaming}/claude-code-edamame"
    STATE_HOME="${LOCALAPPDATA:-$HOME/AppData/Local}/claude-code-edamame/state"
    DATA_HOME="${LOCALAPPDATA:-$HOME/AppData/Local}/claude-code-edamame"
    ;;
  *)
    CONFIG_HOME="${XDG_CONFIG_HOME:-$HOME/.config}/claude-code-edamame"
    STATE_HOME="${XDG_STATE_HOME:-$HOME/.local/state}/claude-code-edamame"
    DATA_HOME="${XDG_DATA_HOME:-$HOME/.local/share}/claude-code-edamame"
    ;;
esac

INSTALL_ROOT="$DATA_HOME/current"
CONFIG_PATH="$CONFIG_HOME/config.json"
CLAUDE_CODE_MCP_PATH="$CONFIG_HOME/claude-code-mcp.json"
NODE_BIN="$(command -v node)"

mkdir -p "$CONFIG_HOME" "$STATE_HOME" "$DATA_HOME"
rm -rf "$INSTALL_ROOT"
mkdir -p "$INSTALL_ROOT"

cp -R "$SOURCE_ROOT/bridge" "$INSTALL_ROOT/"
cp -R "$SOURCE_ROOT/adapters" "$INSTALL_ROOT/"
cp -R "$SOURCE_ROOT/prompts" "$INSTALL_ROOT/"
cp -R "$SOURCE_ROOT/service" "$INSTALL_ROOT/"
cp -R "$SOURCE_ROOT/docs" "$INSTALL_ROOT/"
cp -R "$SOURCE_ROOT/tests" "$INSTALL_ROOT/"
cp -R "$SOURCE_ROOT/setup" "$INSTALL_ROOT/"
cp "$SOURCE_ROOT/package.json" "$INSTALL_ROOT/"
cp "$SOURCE_ROOT/README.md" "$INSTALL_ROOT/"

cp -R "$SOURCE_ROOT/agents" "$INSTALL_ROOT/"
cp -R "$SOURCE_ROOT/assets" "$INSTALL_ROOT/"
cp -R "$SOURCE_ROOT/skills" "$INSTALL_ROOT/"
cp -R "$SOURCE_ROOT/.claude-plugin" "$INSTALL_ROOT/"
if [[ -f "$SOURCE_ROOT/.mcp.json" ]]; then
  cp "$SOURCE_ROOT/.mcp.json" "$INSTALL_ROOT/"
fi

case "$OS_KERNEL" in
  MINGW*|MSYS*|CYGWIN*) ;;
  *)
    chmod +x "$INSTALL_ROOT/bridge/"*.mjs
    chmod +x "$INSTALL_ROOT/service/"*.mjs
    chmod +x "$INSTALL_ROOT/setup/"*.sh
    ;;
esac

export INSTALL_ROOT CONFIG_PATH CLAUDE_CODE_MCP_PATH WORKSPACE_ROOT STATE_HOME NODE_BIN
python3 - <<'PY'
import hashlib
import json
import os
import socket
import sys
from pathlib import Path

install_root = Path(os.environ["INSTALL_ROOT"])
config_path = Path(os.environ["CONFIG_PATH"])
claude_code_mcp_path = Path(os.environ["CLAUDE_CODE_MCP_PATH"])
workspace_root = Path(os.environ["WORKSPACE_ROOT"]).resolve()
state_home = Path(os.environ["STATE_HOME"])
node_bin = os.environ["NODE_BIN"]
default_agent_instance_id = (
    f"{socket.gethostname()}-"
    f"{hashlib.sha256(str(workspace_root).encode('utf-8')).hexdigest()[:12]}"
)
if sys.platform.startswith("linux"):
    default_host_kind = "edamame_posture"
    default_posture_cli_command = "edamame_posture"
elif sys.platform == "win32":
    default_host_kind = "edamame_app"
    default_posture_cli_command = ""
else:
    default_host_kind = "edamame_app"
    default_posture_cli_command = ""
default_psk_path = state_home / "edamame-mcp.psk"
edamame_mcp_psk_file = str(default_psk_path)

def portable_path(p):
    """Forward slashes on all platforms for JSON/config compatibility."""
    return str(p).replace("\\", "/")

def render_template(src: Path, dst: Path) -> None:
    content = src.read_text(encoding="utf-8")
    content = (
        content.replace("__PACKAGE_ROOT__", portable_path(install_root))
        .replace("__CONFIG_PATH__", portable_path(config_path))
        .replace("__WORKSPACE_ROOT__", portable_path(workspace_root))
        .replace("__WORKSPACE_BASENAME__", workspace_root.name)
        .replace("__DEFAULT_AGENT_INSTANCE_ID__", default_agent_instance_id)
        .replace("__DEFAULT_HOST_KIND__", default_host_kind)
        .replace("__DEFAULT_POSTURE_CLI_COMMAND__", portable_path(default_posture_cli_command) if default_posture_cli_command else "")
        .replace("__STATE_DIR__", portable_path(state_home))
        .replace("__EDAMAME_MCP_PSK_FILE__", portable_path(edamame_mcp_psk_file))
        .replace("__NODE_BIN__", portable_path(node_bin))
    )
    dst.parent.mkdir(parents=True, exist_ok=True)
    dst.write_text(content, encoding="utf-8")

if not config_path.exists():
    render_template(
        install_root / "setup" / "claude-code-edamame-config.template.json",
        config_path,
    )

render_template(
    install_root / "setup" / "claude-code-mcp.template.json",
    claude_code_mcp_path,
)


def inject_mcp_entry(snippet_path, global_config_path):
    """Merge the rendered edamame MCP server entry into the global config."""
    try:
        snippet = json.loads(snippet_path.read_text(encoding="utf-8"))
        entry = snippet.get("mcpServers", {}).get("edamame")
        if entry is None:
            return
    except Exception:
        return
    if global_config_path.exists():
        try:
            cfg = json.loads(global_config_path.read_text(encoding="utf-8"))
        except (json.JSONDecodeError, ValueError):
            print(f"WARNING: {global_config_path} contains malformed JSON, skipping MCP injection")
            return
    else:
        cfg = {}
    backup = Path(str(global_config_path) + ".bak")
    if global_config_path.exists():
        import shutil

        shutil.copy2(global_config_path, backup)
    cfg.setdefault("mcpServers", {})["edamame"] = entry
    global_config_path.parent.mkdir(parents=True, exist_ok=True)
    global_config_path.write_text(json.dumps(cfg, indent=2) + "\n", encoding="utf-8")


inject_mcp_entry(claude_code_mcp_path, Path.home() / ".claude.json")
PY

cat <<EOF
Installed Claude Code EDAMAME package to:
  $INSTALL_ROOT

Primary config:
  $CONFIG_PATH

Claude Code MCP snippet:
  $CLAUDE_CODE_MCP_PATH

MCP server registered automatically in ~/.claude.json

Next steps:
1. Launch Claude Code and run the edamame_claude_code_control_center tool.
2. macOS/Windows: click 'Request pairing from app' in the control center, or paste a PSK manually.
   Linux: use the auto-pair action or paste a PSK generated with edamame-posture mcp-generate-psk.
3. Run: "$INSTALL_ROOT/setup/healthcheck.sh" --strict --json
EOF
