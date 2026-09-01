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
# 坏 manifest 必须在动任何文件之前就拦住。否则安装照常覆盖入口、坏记录继续留着，
# 直到卸载时才发现恢复不回去——那时入口已经被接管了。
validate_manifest "$MANIFEST" "$BIN_DIR" || {
  printf '已有的安装记录未通过校验，拒绝安装: %s\n' "$MANIFEST" >&2
  printf '请先运行 scripts/uninstall.sh --inspect 查看现状。\n' >&2
  exit 14
}

# 先记录再覆盖，理由同 install-entrypoint-shims.sh。claude-cc 装的是真正的
# launcher 而不是 shim，因此 artifact 记为 binary。
manifest_record "$MANIFEST" claude-cc "$TARGET" binary "$PROJECT_VERSION" \
  "$ROOT_DIR/bin/claude-cc"
install -m 0755 "$ROOT_DIR/bin/claude-cc" "$TARGET"

printf '已安装 CC Switch 入口: %s\n' "$TARGET"
printf '安装记录: %s\n' "$MANIFEST"
printf '示例配置: %s\n' "$ROOT_DIR/config/safe-claude-cc.example.json"
printf '请确认 ~/.safe-claude-cc.json 固定了独立客户端版本、SHA-256 与本机 CC Switch 端点。\n'
