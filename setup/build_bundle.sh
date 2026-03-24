#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUNDLE_DIR="$ROOT_DIR/dist/claude-code-edamame-bundle"

mkdir -p "$ROOT_DIR/dist"
rm -rf "$BUNDLE_DIR"
mkdir -p "$BUNDLE_DIR"

# Core runtime
cp -R "$ROOT_DIR/bridge" "$BUNDLE_DIR/"
cp -R "$ROOT_DIR/adapters" "$BUNDLE_DIR/"
cp -R "$ROOT_DIR/prompts" "$BUNDLE_DIR/"
cp -R "$ROOT_DIR/service" "$BUNDLE_DIR/"
cp -R "$ROOT_DIR/docs" "$BUNDLE_DIR/"
cp -R "$ROOT_DIR/tests" "$BUNDLE_DIR/"
cp -R "$ROOT_DIR/setup" "$BUNDLE_DIR/"
cp "$ROOT_DIR/package.json" "$BUNDLE_DIR/"
cp "$ROOT_DIR/README.md" "$BUNDLE_DIR/"

cp -R "$ROOT_DIR/agents" "$BUNDLE_DIR/"
cp -R "$ROOT_DIR/assets" "$BUNDLE_DIR/"
cp -R "$ROOT_DIR/skills" "$BUNDLE_DIR/"
[ -d "$ROOT_DIR/scripts" ] && [ "$(ls -A "$ROOT_DIR/scripts" 2>/dev/null)" ] && cp -R "$ROOT_DIR/scripts" "$BUNDLE_DIR/"

chmod +x "$BUNDLE_DIR/bridge/"*.mjs
chmod +x "$BUNDLE_DIR/service/"*.mjs
chmod +x "$BUNDLE_DIR/setup/"*.sh

echo "Built Claude Code bundle at $BUNDLE_DIR"
