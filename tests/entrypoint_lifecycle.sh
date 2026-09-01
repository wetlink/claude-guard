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

# 以下六条来自 PR #21 的独立复审。每一条都对应一个当时能实际复现的失败现场。

manifest_sha() { sha256_file "$(manifest_file)"; }

# --- 14. --dry-run 配合 --adopt-backup 不得写盘 ---
new_prefix
do_install
printf '#!/bin/sh\necho ADOPTED\n' >"$TMP_DIR/adopt-14"
before_sha="$(manifest_sha)"
do_uninstall --dry-run --adopt-backup "claude=$TMP_DIR/adopt-14" ||
  fail '用例 14: dry-run 退出码非零' "$PREFIX/uninstall.out"
[ "$(manifest_sha)" = "$before_sha" ] ||
  fail '用例 14: dry-run 期间 manifest 被改写'

# --- 15. 多个 adoption 不是逐条落盘：后一条失败时前一条也不得生效 ---
new_prefix
do_install
printf '#!/bin/sh\necho ADOPTED\n' >"$TMP_DIR/adopt-15"
before_sha="$(manifest_sha)"
if do_uninstall --adopt-backup "claude=$TMP_DIR/adopt-15" \
                --adopt-backup "claude-official=$TMP_DIR/does-not-exist"; then
  fail '用例 15: 第二条 adoption 不存在却仍然成功'
fi
[ "$(manifest_sha)" = "$before_sha" ] ||
  fail '用例 15: 第一条 adoption 已持久化，但命令报告未做任何修改'

# --- 16. 越界 path 必须 exit 14，且前缀外的文件不得被删除 ---
new_prefix
do_install
printf 'USER DATA\n' >"$TMP_DIR/outside-16.txt"
outside_sha="$(sha256_file "$TMP_DIR/outside-16.txt")"
jq --arg p "$TMP_DIR/outside-16.txt" --arg d "$outside_sha" \
  '.entries |= map(if .name == "claude"
     then .path = $p | .artifact_sha256 = $d | .original = {state: "absent"}
     else . end)' "$(manifest_file)" >"$TMP_DIR/m16" && mv "$TMP_DIR/m16" "$(manifest_file)"
if do_uninstall; then fail '用例 16: 越界 path 竟然执行成功'; fi
[ -e "$TMP_DIR/outside-16.txt" ] || fail '用例 16: 前缀外的文件被删除了'
grep -q 'entry path 必须等于' "$PREFIX/uninstall.out" ||
  fail '用例 16: 未报出 path 越界' "$PREFIX/uninstall.out"

# --- 17. 非法 mode 必须在第一遍就 exit 14，所有入口逐项不变 ---
new_prefix
printf '#!/bin/sh\necho REAL-CLI\n' >"$PREFIX/bin/claude"
chmod 0755 "$PREFIX/bin/claude"
do_install
before_mode="$(snapshot "$PREFIX/bin")"
jq '.entries |= map(if .name == "claude" then .original.mode = "invalid" else . end)' \
  "$(manifest_file)" >"$TMP_DIR/m17" && mv "$TMP_DIR/m17" "$(manifest_file)"
if do_uninstall; then fail '用例 17: 非法 mode 竟然执行成功'; fi
[ "$before_mode" = "$(snapshot "$PREFIX/bin")" ] ||
  fail '用例 17: 第二遍中途失败，留下了恢复一半的现场'

# --- 18. 指向别处 guard 的 shim 不算「我们装的」，必须 exit 14 且不被覆盖 ---
new_prefix
printf '#!/bin/sh\necho REAL-CLI\n' >"$PREFIX/bin/claude"
chmod 0755 "$PREFIX/bin/claude"
do_install
shim_body "/somewhere/else/bin/claude-guard" >"$PREFIX/bin/claude"
foreign_sha="$(sha256_file "$PREFIX/bin/claude")"
if do_uninstall; then fail '用例 18: 外来 shim 竟然被当成我们装的'; fi
[ "$(sha256_file "$PREFIX/bin/claude")" = "$foreign_sha" ] ||
  fail '用例 18: 外来 shim 被覆盖了'

# --- 19. 安装在「备份已放好、manifest 未提交」处被打断后，重试必须能继续 ---
# 这是 cp 与 mv 之间那个窗口被打断后的现场。旧实现会撞上「备份文件已存在」而永久
# 卡死，用户没有任何出路。
new_prefix
printf '#!/bin/sh\necho REAL-CLI\n' >"$PREFIX/bin/claude"
chmod 0755 "$PREFIX/bin/claude"
original_sha="$(sha256_file "$PREFIX/bin/claude")"
cp -p "$PREFIX/bin/claude" "$PREFIX/bin/claude.claude-guard-backup"
do_install
do_uninstall || fail '用例 19: 中断后重试的卸载失败' "$PREFIX/uninstall.out"
[ "$(sha256_file "$PREFIX/bin/claude")" = "$original_sha" ] ||
  fail '用例 19: 复用中断留下的备份后没有还原出原始 CLI'

# 以下五条来自 PR #21 的第二轮独立复审。

# --- 20. --dry-run 不得改动真实备份的权限位 ---
# 上一版为了确认 mode 可用，直接对真实备份 chmod，于是「预演」自己成了副作用。
new_prefix
printf '#!/bin/sh\necho REAL-CLI\n' >"$PREFIX/bin/claude"
chmod 0755 "$PREFIX/bin/claude"
do_install
jq '.entries |= map(if .name == "claude" then .original.mode = "600" else . end)' \
  "$(manifest_file)" >"$TMP_DIR/m20" && mv "$TMP_DIR/m20" "$(manifest_file)"
do_uninstall --dry-run || fail '用例 20: dry-run 退出码非零' "$PREFIX/uninstall.out"
[ "$(file_mode "$PREFIX/bin/claude.claude-guard-backup")" = "755" ] ||
  fail '用例 20: dry-run 改动了真实备份的权限位'

# --- 21. 备份路径是 symlink 时必须拒绝，绝不能顺着写到前缀之外 ---
new_prefix
printf '#!/bin/sh\necho REAL-CLI\n' >"$PREFIX/bin/claude"
chmod 0755 "$PREFIX/bin/claude"
do_install
printf 'OUTSIDE\n' >"$TMP_DIR/outside-21"
chmod 0600 "$TMP_DIR/outside-21"
rm -f "$PREFIX/bin/claude.claude-guard-backup"
ln -s "$TMP_DIR/outside-21" "$PREFIX/bin/claude.claude-guard-backup"
if do_uninstall --dry-run; then fail '用例 21: 备份是 symlink 竟然通过'; fi
[ "$(file_mode "$TMP_DIR/outside-21")" = "600" ] ||
  fail '用例 21: 顺着 symlink 改动了前缀之外的文件'

# --- 22. binary 类入口不接受 shim 兜底 ---
new_prefix
do_install
# 经临时文件再就位：直接重定向到同一路径会被 ShellCheck 判为同一管线内读写同一文件。
shim_body "$PREFIX/bin/claude-guard" >"$TMP_DIR/guard-as-shim"
cp "$TMP_DIR/guard-as-shim" "$PREFIX/bin/claude-guard"
guard_sha="$(sha256_file "$PREFIX/bin/claude-guard")"
if do_uninstall; then fail '用例 22: claude-guard 被换成 shim 后竟然通过'; fi
[ "$(sha256_file "$PREFIX/bin/claude-guard")" = "$guard_sha" ] ||
  fail '用例 22: binary 入口被删除了'

# --- 23. 中断复用只接受与当前入口逐字节相同的备份 ---
# 真正的中断窗口发生在入口尚未被覆盖时，因此备份必然等于当前入口。任何证明不了
# 来源的备份都要交给人去指认，不能静默认作原件。
new_prefix
printf '#!/bin/sh\necho REAL-CLI\n' >"$PREFIX/bin/claude"
chmod 0755 "$PREFIX/bin/claude"
printf '#!/bin/sh\necho UNRELATED\n' >"$PREFIX/bin/claude.claude-guard-backup"
set +e
CLAUDE_GUARD_PREFIX="$PREFIX" "$ROOT_DIR/scripts/install-entrypoint-shims.sh" \
  >"$PREFIX/install.out" 2>&1
status=$?
set -e
[ "$status" -ne 0 ] || fail '用例 23: 来源不明的备份被静默认作原件' "$PREFIX/install.out"
grep -q -- '--adopt-backup' "$PREFIX/install.out" ||
  fail '用例 23: 未提示用 --adopt-backup 指认' "$PREFIX/install.out"

# --- 24. 卸载中途被打断后必须可以重跑 ---
# 构造「claude 已恢复且其备份已回收、claude-official 仍是 shim、guard 还在、manifest
# 还没删」的半完成现场——这正是在 reclaim_backups 之后、删除 manifest 之前被打断的
# 样子。备份已经没了，重跑只能靠「认出这一份已经是原件」，不能靠重新复制备份。
new_prefix
printf '#!/bin/sh\necho REAL-CLI\n' >"$PREFIX/bin/claude"
chmod 0755 "$PREFIX/bin/claude"
original_24="$(sha256_file "$PREFIX/bin/claude")"
do_install
cp -p "$PREFIX/bin/claude.claude-guard-backup" "$PREFIX/bin/claude"
rm -f "$PREFIX/bin/claude.claude-guard-backup"
do_uninstall || fail '用例 24: 半完成状态下重跑卸载失败' "$PREFIX/uninstall.out"
[ "$(sha256_file "$PREFIX/bin/claude")" = "$original_24" ] ||
  fail '用例 24: 重跑后 claude 不是原件'
[ ! -e "$PREFIX/bin/claude-official" ] || fail '用例 24: claude-official 未被清理'
[ ! -e "$PREFIX/bin/claude-guard" ] || fail '用例 24: claude-guard 未被清理'

# --- 25. 坏 manifest 下重装必须 fail-closed，入口与 manifest 均不变 ---
new_prefix
printf '#!/bin/sh\necho REAL-CLI\n' >"$PREFIX/bin/claude"
chmod 0755 "$PREFIX/bin/claude"
do_install
jq --arg p "/tmp/evil-path-25" \
  '.entries |= map(if .name == "claude" then .path = $p else . end)' \
  "$(manifest_file)" >"$TMP_DIR/m25" && mv "$TMP_DIR/m25" "$(manifest_file)"
before_bad="$(snapshot "$PREFIX/bin")"
before_bad_manifest="$(sha256_file "$(manifest_file)")"
set +e
CLAUDE_GUARD_PREFIX="$PREFIX" "$ROOT_DIR/scripts/install-entrypoint-shims.sh" \
  >"$PREFIX/install.out" 2>&1
status=$?
set -e
[ "$status" -ne 0 ] || fail '用例 25: 坏 manifest 下重装竟然成功' "$PREFIX/install.out"
[ "$before_bad" = "$(snapshot "$PREFIX/bin")" ] || fail '用例 25: 坏 manifest 下入口被改动'
[ "$(sha256_file "$(manifest_file)")" = "$before_bad_manifest" ] ||
  fail '用例 25: 坏 manifest 被改写'

# --- 26. manifest 自称 claude-guard 是 shim 时必须在校验阶段就拒绝 ---
# 用例 22 拦的是「文件被换成 shim」，由 check_entry 的类型限制负责；这一条拦的是
# 「记录本身声称类型不对」，由 validate_manifest 负责。两道防线打的不是同一个靶。
new_prefix
do_install
jq '.entries |= map(if .name == "claude-guard" then .artifact = "shim" else . end)' \
  "$(manifest_file)" >"$TMP_DIR/m26" && mv "$TMP_DIR/m26" "$(manifest_file)"
if do_uninstall; then fail '用例 26: manifest 里 artifact 类型错误竟然通过'; fi
grep -q 'artifact 必须是 binary' "$PREFIX/uninstall.out" ||
  fail '用例 26: 未报出 artifact 类型不符' "$PREFIX/uninstall.out"

printf 'entrypoint lifecycle ok\n'
