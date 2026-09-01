#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/lib/entrypoint-manifest.sh
. "$ROOT_DIR/scripts/lib/entrypoint-manifest.sh"

require_cmd jq

PROJECT_VERSION="$(tr -d '[:space:]' <"$ROOT_DIR/VERSION")"
PREFIX="${CLAUDE_GUARD_PREFIX:-$HOME/.local}"
BIN_DIR="$PREFIX/bin"
TARGET="$BIN_DIR/claude-cc"
MANIFEST="$(manifest_path "$PREFIX")"

mkdir -p "$BIN_DIR"
manifest_init "$MANIFEST"

# 先记录再覆盖，理由同 install-entrypoint-shims.sh。claude-cc 装的是真正的
# launcher 而不是 shim，因此 artifact 记为 binary。
manifest_record "$MANIFEST" claude-cc "$TARGET" binary "$PROJECT_VERSION" \
  "$ROOT_DIR/bin/claude-cc"
install -m 0755 "$ROOT_DIR/bin/claude-cc" "$TARGET"

printf '已安装 CC Switch 入口: %s\n' "$TARGET"
printf '安装记录: %s\n' "$MANIFEST"
printf '示例配置: %s\n' "$ROOT_DIR/config/safe-claude-cc.example.json"
printf '请确认 ~/.safe-claude-cc.json 固定了独立客户端版本、SHA-256 与本机 CC Switch 端点。\n'
