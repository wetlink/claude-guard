#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/lib/entrypoint-manifest.sh
. "$ROOT_DIR/scripts/lib/entrypoint-manifest.sh"

require_cmd jq

PROJECT_VERSION="$(tr -d '[:space:]' <"$ROOT_DIR/VERSION")"
PREFIX="${CLAUDE_GUARD_PREFIX:-$HOME/.local}"
BIN_DIR="$PREFIX/bin"
GUARD_TARGET="$BIN_DIR/claude-guard"
MANIFEST="$(manifest_path "$PREFIX")"

mkdir -p "$BIN_DIR"

install_shim() {
  local name="$1"
  local target="$BIN_DIR/$name"
  local tmp

  tmp="$(mktemp)"
  shim_body "$GUARD_TARGET" >"$tmp"
  # 必须先记录再覆盖：manifest_record 只在首次见到该入口时采集 original，之后无论
  # 升级多少个版本都不再重采。旧实现的备份文件名跟随版本号，于是第二次安装会把已经
  # 装好的 shim 当成原始入口备份下来（issue #15）。
  manifest_record "$MANIFEST" "$name" "$target" shim "$PROJECT_VERSION" "$tmp"
  install -m 0755 "$tmp" "$target"
  rm -f "$tmp"
  printf '已安装入口: %s -> %s\n' "$target" "$GUARD_TARGET"
}

manifest_init "$MANIFEST"
# 坏 manifest 必须在动任何文件之前就拦住。否则安装照常覆盖入口、坏记录继续留着，
# 直到卸载时才发现恢复不回去——那时入口已经被接管了。
validate_manifest "$MANIFEST" "$BIN_DIR" || {
  printf '已有的安装记录未通过校验，拒绝安装: %s\n' "$MANIFEST" >&2
  printf '请先运行 scripts/uninstall.sh --inspect 查看现状。\n' >&2
  exit 14
}

manifest_record "$MANIFEST" claude-guard "$GUARD_TARGET" binary "$PROJECT_VERSION" \
  "$ROOT_DIR/bin/claude-guard"
install -m 0755 "$ROOT_DIR/bin/claude-guard" "$GUARD_TARGET"
printf '已安装 guard: %s\n' "$GUARD_TARGET"

install_shim claude
install_shim claude-official

printf '入口已收敛：claude 与 claude-official 都会先进入 claude-guard。\n'
printf '安装记录: %s\n' "$MANIFEST"
printf '请确认 ~/.safe-claude-official.json 的 command 仍指向原始 Claude CLI 绝对路径，而不是上述 shim。\n'
printf '卸载执行 scripts/uninstall.sh；先跑 scripts/uninstall.sh --inspect 可只读查看现状。\n'
