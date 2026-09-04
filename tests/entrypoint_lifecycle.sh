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

# --- 21. 卸载侧：固定备份路径变成 symlink 时必须拒绝 ---
# 关键在于外部目标的内容与记录里的原备份**完全相同**，只有 mode 不同。这样摘要检查
# 不会替 symlink 判定挡枪，去掉卸载侧的 [ -L ] 之后这条用例才会真的变红。
# 我们创建的 managed 备份永远是 cp 出来的普通文件；固定路径上出现 symlink 就意味着
# 它不是我们放的，必须 fail-closed。
new_prefix
printf '#!/bin/sh\necho REAL-CLI\n' >"$PREFIX/bin/claude"
chmod 0755 "$PREFIX/bin/claude"
do_install
printf '#!/bin/sh\necho REAL-CLI\n' >"$TMP_DIR/outside-21"
chmod 0600 "$TMP_DIR/outside-21"
[ "$(sha256_file "$TMP_DIR/outside-21")" = \
  "$(sha256_file "$PREFIX/bin/claude.claude-guard-backup")" ] ||
  fail '用例 21: 前提不成立，外部目标必须与原备份内容相同'
rm -f "$PREFIX/bin/claude.claude-guard-backup"
ln -s "$TMP_DIR/outside-21" "$PREFIX/bin/claude.claude-guard-backup"
if do_uninstall; then fail '用例 21: 备份路径是 symlink 竟然通过'; fi
[ -e "$TMP_DIR/outside-21" ] || fail '用例 21: 前缀之外的文件被删除了'

# --- 21b. 安装侧：固定备份路径已是 symlink 时必须拒绝复用 ---
# 同样让内容相同，否则摘要比对会先一步拦下，capture_original 的 [ -L ] 就测不到。
new_prefix
printf '#!/bin/sh\necho REAL-CLI\n' >"$PREFIX/bin/claude"
chmod 0755 "$PREFIX/bin/claude"
printf '#!/bin/sh\necho REAL-CLI\n' >"$TMP_DIR/outside-21b"
ln -s "$TMP_DIR/outside-21b" "$PREFIX/bin/claude.claude-guard-backup"
set +e
CLAUDE_GUARD_PREFIX="$PREFIX" "$ROOT_DIR/scripts/install-entrypoint-shims.sh" \
  >"$PREFIX/install.out" 2>&1
status=$?
set -e
[ "$status" -ne 0 ] || fail '用例 21b: 备份路径是 symlink 时仍然复用了它' "$PREFIX/install.out"
grep -q '不是普通文件' "$PREFIX/install.out" ||
  fail '用例 21b: 未报出备份不是普通文件' "$PREFIX/install.out"

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
# 人为构造的半完成恢复现场：claude 已恢复且其备份已不在，claude-official 仍是 shim，
# guard 还在，manifest 未删。这不完全对应某个真实时点（真到 reclaim 之后，其余 entry
# 也都已恢复），但它精确覆盖了要测的那条路径——备份已经没了，重跑只能靠「认出这一份
# 已经是原件」，不能靠重新复制备份。
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

# --- 27. 指认的备份即使恰好在固定路径上也不得删除 ---
# 「谁拥有这份备份」由 manifest 里的 backup_origin 说了算，不由文件名推断。
new_prefix
do_install
printf '#!/bin/sh\necho ADOPTED-AT-MANAGED-PATH\n' >"$PREFIX/bin/claude.claude-guard-backup"
do_uninstall --adopt-backup "claude=$PREFIX/bin/claude.claude-guard-backup" ||
  fail '用例 27: 指认固定路径上的备份被拒绝' "$PREFIX/uninstall.out"
[ -e "$PREFIX/bin/claude.claude-guard-backup" ] ||
  fail '用例 27: 被显式指认的备份文件被自动删除了'
grep -q 'ADOPTED-AT-MANAGED-PATH' "$PREFIX/bin/claude" ||
  fail '用例 27: 未按指认的备份还原'

# --- 28. 执行阶段失败必须说实话，且可以重跑 ---
# 确定性的 I/O 故障注入：PATH 上放一个第三次调用才失败的假 cp。三次分别是候选 manifest
# 的复制、claude 的恢复、claude-official 的恢复，因此第一个入口成功、第二个失败。
new_prefix
printf '#!/bin/sh\necho REAL-CLI\n' >"$PREFIX/bin/claude"
printf '#!/bin/sh\necho REAL-OFFICIAL\n' >"$PREFIX/bin/claude-official"
chmod 0755 "$PREFIX/bin/claude" "$PREFIX/bin/claude-official"
claude_original_28="$(sha256_file "$PREFIX/bin/claude")"
do_install
mkdir -p "$TMP_DIR/fakebin-28"
cat >"$TMP_DIR/fakebin-28/cp" <<'FAKE'
#!/usr/bin/env bash
count_file="$CLAUDE_GUARD_CP_COUNT"
n=$(( $(cat "$count_file" 2>/dev/null || echo 0) + 1 ))
printf '%s\n' "$n" >"$count_file"
if [ "$n" -ge 3 ]; then
  printf 'cp: injected failure\n' >&2
  exit 1
fi
exec /bin/cp "$@"
FAKE
chmod +x "$TMP_DIR/fakebin-28/cp"
: >"$TMP_DIR/cp-count-28"
set +e
CLAUDE_GUARD_PREFIX="$PREFIX" CLAUDE_GUARD_CP_COUNT="$TMP_DIR/cp-count-28" \
  PATH="$TMP_DIR/fakebin-28:$PATH" \
  "$ROOT_DIR/scripts/uninstall.sh" >"$PREFIX/uninstall.out" 2>&1
status=$?
set -e
[ "$status" -ne 0 ] || fail '用例 28: 注入复制失败后仍返回 0' "$PREFIX/uninstall.out"
if grep -q '未做任何修改' "$PREFIX/uninstall.out"; then
  fail '用例 28: 执行阶段失败仍谎称未做任何修改' "$PREFIX/uninstall.out"
fi
grep -q '可以直接重跑' "$PREFIX/uninstall.out" ||
  fail '用例 28: 未告知可以重跑' "$PREFIX/uninstall.out"
# guard 排在最后处理，失败时必须还在，否则重跑就没有 guard 了。
[ -e "$PREFIX/bin/claude-guard" ] ||
  fail '用例 28: 失败时 claude-guard 已被删除' "$PREFIX/uninstall.out"
# 修复条件后重跑必须收口。
do_uninstall || fail '用例 28: 修复后重跑仍失败' "$PREFIX/uninstall.out"
[ "$(sha256_file "$PREFIX/bin/claude")" = "$claude_original_28" ] ||
  fail '用例 28: 重跑后 claude 不是原件'
grep -q 'REAL-OFFICIAL' "$PREFIX/bin/claude-official" ||
  fail '用例 28: 重跑后 claude-official 未还原'
[ ! -e "$PREFIX/bin/claude-guard" ] || fail '用例 28: 重跑后 claude-guard 未清理'

# --- 29. 跨 entry 的所有权冲突必须在第一遍拒绝 ---
# 单看任何一条记录都合法：claude 把某路径标成 adopted（承诺不删），claude-official 把
# 同一路径标成 managed（卸载完要删）。合起来就让「指认的那一份也不删」被一组合法参数
# 打破。所有权必须在记录之间也一致。
new_prefix
printf '#!/bin/sh\necho REAL-C\n' >"$PREFIX/bin/claude"
printf '#!/bin/sh\necho REAL-O\n' >"$PREFIX/bin/claude-official"
chmod 0755 "$PREFIX/bin/claude" "$PREFIX/bin/claude-official"
do_install
shared_29="$PREFIX/bin/claude-official.claude-guard-backup"
before_29="$(snapshot "$PREFIX/bin")"
before_29_manifest="$(sha256_file "$(manifest_file)")"
if do_uninstall --adopt-backup "claude=$shared_29"; then
  fail '用例 29: 跨 entry 所有权冲突竟然通过'
fi
[ -e "$shared_29" ] || fail '用例 29: 冲突被放行，共享备份已被删除'
[ "$before_29" = "$(snapshot "$PREFIX/bin")" ] || fail '用例 29: 拒绝之后入口仍被改动'
[ "$(sha256_file "$(manifest_file)")" = "$before_29_manifest" ] ||
  fail '用例 29: 拒绝之后 manifest 被改写'
grep -q '同时声明所有权' "$PREFIX/uninstall.out" ||
  fail '用例 29: 未报出所有权冲突' "$PREFIX/uninstall.out"

# --- 30. 回收阶段的 I/O 失败也必须落到分阶段提示上，且提示要与现场相符 ---
# 两个入口各有一份 managed 备份，让假 rm 只在回收第二份时失败。这样现场是「第一份已
# 回收、第二份还在」——文案就不能笼统地说「备份都已保留」。
new_prefix
printf '#!/bin/sh\necho REAL-C\n' >"$PREFIX/bin/claude"
printf '#!/bin/sh\necho REAL-O\n' >"$PREFIX/bin/claude-official"
chmod 0755 "$PREFIX/bin/claude" "$PREFIX/bin/claude-official"
original_30="$(sha256_file "$PREFIX/bin/claude")"
do_install
mkdir -p "$TMP_DIR/fakebin-30"
cat >"$TMP_DIR/fakebin-30/rm" <<'FAKE'
#!/usr/bin/env bash
for a in "$@"; do
  case "$a" in
    *claude-official.claude-guard-backup)
      printf 'rm: injected reclaim failure\n' >&2
      exit 1
      ;;
  esac
done
exec /bin/rm "$@"
FAKE
chmod +x "$TMP_DIR/fakebin-30/rm"
set +e
CLAUDE_GUARD_PREFIX="$PREFIX" PATH="$TMP_DIR/fakebin-30:$PATH" \
  "$ROOT_DIR/scripts/uninstall.sh" >"$PREFIX/uninstall.out" 2>&1
status=$?
set -e
[ "$status" -eq 14 ] ||
  fail "用例 30: 回收失败应以 14 退出，实际 ${status}" "$PREFIX/uninstall.out"
# 现场：第一份已回收、第二份还在、manifest 还在。
[ ! -e "$PREFIX/bin/claude.claude-guard-backup" ] ||
  fail '用例 30: 第一份备份应已回收'
[ -e "$PREFIX/bin/claude-official.claude-guard-backup" ] ||
  fail '用例 30: 第二份备份不该消失'
[ -e "$(manifest_file)" ] || fail '用例 30: 安装记录不该被删除'
if grep -q '未做任何修改' "$PREFIX/uninstall.out"; then
  fail '用例 30: 回收阶段失败仍谎称未做任何修改' "$PREFIX/uninstall.out"
fi
if grep -q '备份都已保留' "$PREFIX/uninstall.out"; then
  fail '用例 30: 已回收一份却声称备份都已保留' "$PREFIX/uninstall.out"
fi
grep -q '可以直接重跑' "$PREFIX/uninstall.out" ||
  fail '用例 30: 回收失败未告知可以重跑' "$PREFIX/uninstall.out"
do_uninstall || fail '用例 30: 去掉注入后重跑仍失败' "$PREFIX/uninstall.out"
[ "$(sha256_file "$PREFIX/bin/claude")" = "$original_30" ] ||
  fail '用例 30: 重跑后 claude 不是原件'

# --- 31. managed 的备份路径必须固定，不得指向前缀之外 ---
# 与用例 29 打的不是同一个靶：29 是「两条记录对同一路径声明相反所有权」，这一条是
# 「单条记录把任意外部路径标成 managed」。约束一旦回归，回收逻辑就会去删它。
new_prefix
printf '#!/bin/sh\necho REAL-CLI\n' >"$PREFIX/bin/claude"
chmod 0755 "$PREFIX/bin/claude"
do_install
# 内容必须与真实 managed 备份逐字节相同，否则摘要检查会先一步拦住，路径校验这道门
# 就测不到；断言的重点是「外部文件有没有被删」这个行为，文案只是补充。
cp -p "$PREFIX/bin/claude.claude-guard-backup" "$TMP_DIR/outside-31"
jq --arg p "$TMP_DIR/outside-31" \
  '.entries |= map(if .name == "claude" then .original.backup_path = $p else . end)' \
  "$(manifest_file)" >"$TMP_DIR/m31" && mv "$TMP_DIR/m31" "$(manifest_file)"
before_31="$(snapshot "$PREFIX/bin")"
if do_uninstall; then fail '用例 31: managed 指向前缀外竟然通过'; fi
[ -e "$TMP_DIR/outside-31" ] || fail '用例 31: 前缀外的文件被删除了'
[ "$before_31" = "$(snapshot "$PREFIX/bin")" ] || fail '用例 31: 拒绝之后入口仍被改动'
grep -q 'managed 备份路径必须是' "$PREFIX/uninstall.out" ||
  fail '用例 31: 未报出 managed 路径越界' "$PREFIX/uninstall.out"

# --- 32. 非规范路径别名不得绕过所有权校验 ---
# $BIN/../bin/x 与 $BIN/x 是同一个文件，但字符串不同。用例 29 拦的是「字面相同」，
# 这一条拦的是「解析后相同」——只比字符串等于没比。
new_prefix
printf '#!/bin/sh\necho REAL-C\n' >"$PREFIX/bin/claude"
printf '#!/bin/sh\necho REAL-O\n' >"$PREFIX/bin/claude-official"
chmod 0755 "$PREFIX/bin/claude" "$PREFIX/bin/claude-official"
do_install
shared_32="$PREFIX/bin/claude-official.claude-guard-backup"
alias_32="$PREFIX/bin/../bin/claude-official.claude-guard-backup"
before_32="$(snapshot "$PREFIX/bin")"
before_32_manifest="$(sha256_file "$(manifest_file)")"
if do_uninstall --adopt-backup "claude=$alias_32"; then
  fail '用例 32: ../ 别名绕过了所有权校验'
fi
[ -e "$shared_32" ] || fail '用例 32: 别名被放行，共享备份已被删除'
[ "$before_32" = "$(snapshot "$PREFIX/bin")" ] || fail '用例 32: 拒绝之后入口仍被改动'
[ "$(sha256_file "$(manifest_file)")" = "$before_32_manifest" ] ||
  fail '用例 32: 拒绝之后 manifest 被改写'

# --- 33. macOS 大小写别名不得绕过所有权校验 ---
# APFS 默认大小写不敏感，CLAUDE-OFFICIAL.CLAUDE-GUARD-BACKUP 与小写是同一个目录项，
# 字符串归一认不出来，只有 -ef 认得出来。先断言两个名字确实是同一个文件，否则在大小写
# 敏感卷（Linux CI）上它们是两个不同文件，这条用例根本不成立，跳过而不是假绿。
new_prefix
printf '#!/bin/sh\necho REAL-C\n' >"$PREFIX/bin/claude"
printf '#!/bin/sh\necho REAL-O\n' >"$PREFIX/bin/claude-official"
chmod 0755 "$PREFIX/bin/claude" "$PREFIX/bin/claude-official"
do_install
managed_33="$PREFIX/bin/claude-official.claude-guard-backup"
alias_33="$PREFIX/bin/CLAUDE-OFFICIAL.CLAUDE-GUARD-BACKUP"
if [ "$managed_33" -ef "$alias_33" ]; then
  before_33="$(snapshot "$PREFIX/bin")"
  before_33_manifest="$(sha256_file "$(manifest_file)")"
  if do_uninstall --adopt-backup "claude=$alias_33"; then
    fail '用例 33: 大小写别名绕过了所有权校验'
  fi
  [ -e "$managed_33" ] || fail '用例 33: 别名被放行，共享备份已被删除'
  [ "$before_33" = "$(snapshot "$PREFIX/bin")" ] || fail '用例 33: 拒绝之后入口仍被改动'
  [ "$(sha256_file "$(manifest_file)")" = "$before_33_manifest" ] ||
    fail '用例 33: 拒绝之后 manifest 被改写'
else
  printf '用例 33: 当前卷大小写敏感，别名不是同一文件，跳过\n'
fi

# --- 34. 三个安装器都必须拒绝带所有权冲突的 manifest ---
# 所有权不变式的消费者不止卸载器：预置一份单条合法、合起来冲突（../ 别名）的 manifest，
# 三个安装器在改任何 artifact 之前都必须 exit 14，入口与 manifest 逐项不变。
new_prefix
printf '#!/bin/sh\necho REAL-C\n' >"$PREFIX/bin/claude"
printf '#!/bin/sh\necho REAL-O\n' >"$PREFIX/bin/claude-official"
chmod 0755 "$PREFIX/bin/claude" "$PREFIX/bin/claude-official"
do_install
jq --arg p "$PREFIX/bin/../bin/claude-official.claude-guard-backup" \
  '.entries |= map(if .name == "claude"
     then .original.backup_path = $p | .original.backup_origin = "adopted"
     else . end)' "$(manifest_file)" >"$TMP_DIR/m34" && mv "$TMP_DIR/m34" "$(manifest_file)"
before_34="$(snapshot "$PREFIX/bin")"
before_34_manifest="$(sha256_file "$(manifest_file)")"
for installer in install.sh install-cc-entrypoint.sh install-entrypoint-shims.sh; do
  set +e
  CLAUDE_GUARD_PREFIX="$PREFIX" "$ROOT_DIR/scripts/$installer" >"$PREFIX/install.out" 2>&1
  status=$?
  set -e
  [ "$status" -eq 14 ] ||
    fail "用例 34: $installer 在冲突 manifest 下应 exit 14，实际 ${status}" "$PREFIX/install.out"
  [ "$before_34" = "$(snapshot "$PREFIX/bin")" ] || fail "用例 34: $installer 改动了入口"
  [ "$(sha256_file "$(manifest_file)")" = "$before_34_manifest" ] ||
    fail "用例 34: $installer 改写了 manifest"
  grep -q '所有权冲突' "$PREFIX/install.out" ||
    fail "用例 34: $installer 未报出所有权冲突" "$PREFIX/install.out"
done

printf 'entrypoint lifecycle ok\n'
