#!/usr/bin/env bash
set -euo pipefail

# 入口安装/卸载的 round-trip 回归。核心断言只有一句：卸载之后，前缀目录必须与安装前
# 逐项相同。symlink 比对的是 target 而不是内容——issue #15 的第二层缺陷正是 cp -p 把
# symlink 展平成普通文件，只比内容会完全漏掉它。

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/lib/entrypoint-manifest.sh
. "$ROOT_DIR/scripts/lib/entrypoint-manifest.sh"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

CASE_NO=0
PREFIX=''

fail() {
  printf '%s\n' "$1" >&2
  shift
  if [ "$#" -gt 0 ]; then
    cat "$@" >&2
  fi
  exit 1
}

new_prefix() {
  CASE_NO=$((CASE_NO + 1))
  PREFIX="$TMP_DIR/case$CASE_NO"
  mkdir -p "$PREFIX/bin"
}

# 目录快照：名字 + 类型 + 内容标识。symlink 记 target，普通文件记摘要与权限位。
snapshot() {
  local dir="$1" entry name
  find "$dir" -mindepth 1 -maxdepth 1 | LC_ALL=C sort | while IFS= read -r entry; do
    name="$(basename "$entry")"
    if [ -L "$entry" ]; then
      printf '%s symlink %s\n' "$name" "$(readlink "$entry")"
    elif [ -f "$entry" ]; then
      printf '%s file %s %s\n' "$name" "$(sha256_file "$entry")" "$(file_mode "$entry")"
    else
      printf '%s other\n' "$name"
    fi
  done
}

# 安装的输出落在 install.out 里，失败时必须主动打出来。否则安装一旦失败，set -e
# 会静默中断整个测试，留下一个「变红但什么都没说」的现场。
do_install() {
  local status
  set +e
  CLAUDE_GUARD_PREFIX="$PREFIX" "$ROOT_DIR/scripts/install-entrypoint-shims.sh" \
    >"$PREFIX/install.out" 2>&1
  status=$?
  set -e
  [ "$status" -eq 0 ] || fail "安装失败（exit ${status}）" "$PREFIX/install.out"
}

# 运行卸载并返回退出码，不让 set -e 提前中断。
do_uninstall() {
  local status
  set +e
  CLAUDE_GUARD_PREFIX="$PREFIX" "$ROOT_DIR/scripts/uninstall.sh" "$@" \
    >"$PREFIX/uninstall.out" 2>&1
  status=$?
  set -e
  return "$status"
}

assert_round_trip() {
  local label="$1"
  local before after

  before="$(snapshot "$PREFIX/bin")"
  do_install
  do_uninstall || fail "$label: 卸载失败" "$PREFIX/uninstall.out"
  after="$(snapshot "$PREFIX/bin")"

  if [ "$before" != "$after" ]; then
    printf '%s: 卸载后与安装前不一致\n' "$label" >&2
    printf -- '--- 安装前 ---\n%s\n--- 卸载后 ---\n%s\n' "$before" "$after" >&2
    exit 1
  fi
}

manifest_file() {
  printf '%s/share/claude-guard/entrypoints.json\n' "$PREFIX"
}

# --- 1. 原入口不存在 ---
new_prefix
assert_round_trip '用例 1（原入口不存在）'
[ ! -e "$PREFIX/bin/claude" ] || fail '用例 1: claude 不该存在'

# --- 2. 原入口是普通文件 ---
new_prefix
printf '#!/bin/sh\necho REAL-CLI\n' >"$PREFIX/bin/claude"
chmod 0755 "$PREFIX/bin/claude"
assert_round_trip '用例 2（普通文件）'
grep -q 'REAL-CLI' "$PREFIX/bin/claude" || fail '用例 2: 内容未还原'

# --- 3. 原入口是 symlink：必须仍是 symlink，不能被展平 ---
new_prefix
printf '#!/bin/sh\necho REAL-CLI\n' >"$TMP_DIR/real-cli-3"
chmod 0755 "$TMP_DIR/real-cli-3"
ln -s "$TMP_DIR/real-cli-3" "$PREFIX/bin/claude"
assert_round_trip '用例 3（symlink）'
[ -L "$PREFIX/bin/claude" ] || fail '用例 3: 恢复后不再是 symlink（被展平了）'

# --- 4. 悬空 symlink：[ -e ] 为假，必须靠 [ -L ] 认出来 ---
new_prefix
ln -s "$TMP_DIR/does-not-exist" "$PREFIX/bin/claude"
assert_round_trip '用例 4（悬空 symlink）'
[ -L "$PREFIX/bin/claude" ] || fail '用例 4: 恢复后不再是 symlink'
[ ! -e "$PREFIX/bin/claude" ] || fail '用例 4: 不该变成可解析的链接'

# --- 5 / 6. 重复安装：original 永不重采，也不产生第二份备份 ---
# 这是 issue #15 的核心回归。旧实现的备份名跟随版本号，第二次安装时新名字不存在，
# 于是把已经装好的 shim 当成原始入口备份下来。新实现不读版本号做备份名，改为
# 「manifest 里已有该条目就不再采集 original」，因此重复安装多少次都等价。
new_prefix
printf '#!/bin/sh\necho REAL-CLI\n' >"$PREFIX/bin/claude"
chmod 0755 "$PREFIX/bin/claude"
original_before="$(sha256_file "$PREFIX/bin/claude")"
do_install
first_original="$(jq -c '.entries[] | select(.name=="claude") | .original' "$(manifest_file)")"
do_install
do_install
second_original="$(jq -c '.entries[] | select(.name=="claude") | .original' "$(manifest_file)")"
[ "$first_original" = "$second_original" ] ||
  fail "用例 5/6: 重复安装改写了 original: $first_original -> $second_original"
backup_count="$(find "$PREFIX/bin" -maxdepth 1 -name '*.claude-guard-backup' | wc -l | tr -d ' ')"
[ "$backup_count" = "1" ] || fail "用例 5/6: 备份份数应为 1，实际 $backup_count"
if is_guard_shim "$PREFIX/bin/claude.claude-guard-backup"; then
  fail '用例 5/6: 备份内容变成了 Guard shim（issue #15 的原始症状）'
fi
do_uninstall || fail '用例 5/6: 卸载失败' "$PREFIX/uninstall.out"
[ "$(sha256_file "$PREFIX/bin/claude")" = "$original_before" ] ||
  fail '用例 5/6: 还原出来的不是真正的原始 CLI'

# --- 7. 安装后被手工改过的入口，拒绝改动 ---
new_prefix
do_install
printf '#!/bin/sh\necho USER-EDITED\n' >"$PREFIX/bin/claude"
before_tamper="$(sha256_file "$PREFIX/bin/claude")"
if do_uninstall; then fail '用例 7: 入口被改过仍然执行了卸载'; fi
[ "$(sha256_file "$PREFIX/bin/claude")" = "$before_tamper" ] ||
  fail '用例 7: 拒绝之后仍然动了文件'
grep -q '可能已被手工修改' "$PREFIX/uninstall.out" ||
  fail '用例 7: 报错未指出入口被修改' "$PREFIX/uninstall.out"

# --- 8. manifest 缺失，fail-closed 并指向 --inspect ---
new_prefix
do_install
rm -f "$(manifest_file)"
if do_uninstall; then fail '用例 8: 没有安装记录仍然执行了卸载'; fi
grep -q -- '--inspect' "$PREFIX/uninstall.out" ||
  fail '用例 8: 报错未提示先跑 --inspect' "$PREFIX/uninstall.out"

# --- 9. 备份内容是 Guard shim：拒绝用它覆盖 ---
new_prefix
printf '#!/bin/sh\necho REAL-CLI\n' >"$PREFIX/bin/claude"
chmod 0755 "$PREFIX/bin/claude"
do_install
shim_body "$PREFIX/bin/claude-guard" >"$PREFIX/bin/claude.claude-guard-backup"
if do_uninstall; then fail '用例 9: 备份是 shim 仍然执行了恢复'; fi
grep -q '备份内容是 Guard shim' "$PREFIX/uninstall.out" ||
  fail '用例 9: 报错未指出备份是 shim' "$PREFIX/uninstall.out"

# --- 10. --adopt-backup：真备份接受，shim 拒绝 ---
new_prefix
do_install
printf '#!/bin/sh\necho ADOPTED-CLI\n' >"$TMP_DIR/adopt-real"
shim_body "$PREFIX/bin/claude-guard" >"$TMP_DIR/adopt-shim"
if do_uninstall --adopt-backup "claude=$TMP_DIR/adopt-shim"; then
  fail '用例 10: 指认 shim 作为备份竟然被接受'
fi
grep -q '内容是 Guard shim' "$PREFIX/uninstall.out" ||
  fail '用例 10: 拒绝理由不对' "$PREFIX/uninstall.out"
do_uninstall --adopt-backup "claude=$TMP_DIR/adopt-real" ||
  fail '用例 10: 指认真备份被拒绝' "$PREFIX/uninstall.out"
grep -q 'ADOPTED-CLI' "$PREFIX/bin/claude" || fail '用例 10: 未按指认的备份还原'

# --- 11. --inspect 必须只读 ---
new_prefix
printf '#!/bin/sh\necho REAL-CLI\n' >"$PREFIX/bin/claude"
chmod 0755 "$PREFIX/bin/claude"
do_install
before_inspect="$(snapshot "$PREFIX/bin")"
do_uninstall --inspect || fail '用例 11: --inspect 退出码非零' "$PREFIX/uninstall.out"
[ "$before_inspect" = "$(snapshot "$PREFIX/bin")" ] || fail '用例 11: --inspect 修改了文件'
[ -e "$(manifest_file)" ] || fail '用例 11: --inspect 删掉了安装记录'

# --- 12. --dry-run 必须只读 ---
new_prefix
printf '#!/bin/sh\necho REAL-CLI\n' >"$PREFIX/bin/claude"
chmod 0755 "$PREFIX/bin/claude"
do_install
before_dry="$(snapshot "$PREFIX/bin")"
do_uninstall --dry-run || fail '用例 12: --dry-run 退出码非零' "$PREFIX/uninstall.out"
[ "$before_dry" = "$(snapshot "$PREFIX/bin")" ] || fail '用例 12: --dry-run 修改了文件'
[ -e "$(manifest_file)" ] || fail '用例 12: --dry-run 删掉了安装记录'

# --- 13. 历史备份永不自动删除 ---
new_prefix
printf '#!/bin/sh\necho REAL-CLI\n' >"$PREFIX/bin/claude"
chmod 0755 "$PREFIX/bin/claude"
printf '#!/bin/sh\necho LEGACY\n' >"$PREFIX/bin/claude.bak-before-claude-guard-v2.0.0"
do_install
do_uninstall || fail '用例 13: 卸载失败' "$PREFIX/uninstall.out"
[ -e "$PREFIX/bin/claude.bak-before-claude-guard-v2.0.0" ] ||
  fail '用例 13: 历史备份被自动删除了'

printf 'entrypoint lifecycle ok\n'
