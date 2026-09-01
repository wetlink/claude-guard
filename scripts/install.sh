#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/lib/entrypoint-manifest.sh
. "$ROOT_DIR/scripts/lib/entrypoint-manifest.sh"

require_cmd jq

PROJECT_VERSION="$(tr -d '[:space:]' <"$ROOT_DIR/VERSION")"
PREFIX="${CLAUDE_GUARD_PREFIX:-$HOME/.local}"
BIN_DIR="$PREFIX/bin"
TARGET="$BIN_DIR/claude-guard"
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

# 这条路径此前既不备份也不留记录，直接覆盖 $BIN_DIR/claude-guard。现在同样进
# manifest，卸载器才能按哈希确认「这份 claude-guard 是我们装的」再移除。
manifest_record "$MANIFEST" claude-guard "$TARGET" binary "$PROJECT_VERSION" \
  "$ROOT_DIR/bin/claude-guard"
install -m 0755 "$ROOT_DIR/bin/claude-guard" "$TARGET"

printf '已安装: %s\n' "$TARGET"
printf '安装记录: %s\n' "$MANIFEST"
printf '示例配置: %s\n' "$ROOT_DIR/config/safe-claude.example.json"
printf '如果要替换当前 claude 入口，请先确认 ~/.safe-claude-official.json 的 command 指向原始 Claude CLI 绝对路径。\n'
