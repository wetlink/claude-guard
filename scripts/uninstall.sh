#!/usr/bin/env bash
set -euo pipefail

# 按 manifest 把入口恢复成安装前的状态，并移除 Guard 自身装进 $PREFIX/bin 的文件。
#
# 全程 fail-closed：任何一项前置条件不满足就整体中止（exit 14），一个文件都不动。
# 尤其不会「尽力而为地恢复一部分」——恢复到一半的入口比不恢复更难排查。
#
# 存量用户（v1.0.0 到 v2.1.x 之间装过的）没有 manifest，且 $PREFIX/bin 里可能同时
# 躺着一个真备份和若干内容其实是 Guard shim 的假备份（issue #15）。这种情况一律先
# 走 --inspect 看清楚，再用 --adopt-backup 显式指认真备份，绝不自动猜。

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/lib/entrypoint-manifest.sh
. "$ROOT_DIR/scripts/lib/entrypoint-manifest.sh"

require_cmd jq

PREFIX="${CLAUDE_GUARD_PREFIX:-$HOME/.local}"
BIN_DIR="$PREFIX/bin"
MANIFEST="$(manifest_path "$PREFIX")"

MODE=apply
DRY_RUN=0
ADOPTIONS=''

usage() {
  printf '用法: uninstall.sh [--inspect | --dry-run] [--adopt-backup <名称>=<路径>]...\n'
  printf '\n'
  printf '  --inspect                     只读。列出每个入口现状、找到的历史备份及其真假判定。\n'
  printf '  --dry-run                     打印将要执行的每一步，不修改任何文件。\n'
  printf '  --adopt-backup <名称>=<路径>  把指定文件认定为该入口的原始备份，写入 manifest。\n'
  printf '                                会先校验它不是 Guard shim。可重复。\n'
  printf '\n'
  # shellcheck disable=SC2016  # 帮助文本要原样显示 $HOME/.local，展开就成了具体路径
  printf '环境变量 CLAUDE_GUARD_PREFIX 决定操作哪个前缀，默认 $HOME/.local。\n'
}

fail_closed() {
  printf '%s\n' "$1" >&2
  printf '未做任何修改。先运行 scripts/uninstall.sh --inspect 查看现状。\n' >&2
  exit 14
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --inspect) MODE=inspect ;;
    --dry-run) DRY_RUN=1 ;;
    --adopt-backup)
      shift
      [ "$#" -gt 0 ] || { usage >&2; exit 2; }
      case "$1" in
        *=*) ADOPTIONS="$ADOPTIONS$1"$'\n' ;;
        *) printf '--adopt-backup 需要 <名称>=<路径> 形式: %s\n' "$1" >&2; exit 2 ;;
      esac
      ;;
    -h|--help) usage; exit 0 ;;
    *) printf '未知参数: %s\n' "$1" >&2; usage >&2; exit 2 ;;
  esac
  shift
done

# 历史遗留的版本号备份。永不自动删除，只列出并给出真假判定——它们里面通常恰好有
# 一个是真原件，其余是被 issue #15 的 bug 备份下来的 shim。
list_legacy_backups() {
  local name="$1"
  find "$BIN_DIR" -maxdepth 1 -name "$name.bak-before-claude-guard-v*" 2>/dev/null | sort
}

describe_entry() {
  local name="$1"
  local path="$BIN_DIR/$name"
  local state legacy verdict

  state="$(entry_state "$path")"
  printf '  %-16s %s' "$name" "$state"
  if [ "$state" = symlink ] || [ "$state" = dangling-symlink ]; then
    printf ' -> %s' "$(readlink "$path")"
  elif [ "$state" = file ]; then
    if is_guard_shim "$path"; then
      printf '（Guard shim）'
    else
      printf '（非 Guard shim）'
    fi
  fi
  printf '\n'

  while IFS= read -r legacy; do
    [ -n "$legacy" ] || continue
    if is_guard_shim "$legacy"; then
      verdict='内容是 Guard shim，不是原始入口'
    else
      verdict='不是 Guard shim，可能是真备份'
    fi
    printf '      历史备份 %s：%s\n' "$legacy" "$verdict"
  done <<EOF
$(list_legacy_backups "$name")
EOF
}

if [ "$MODE" = inspect ]; then
  printf '前缀: %s\n' "$PREFIX"
  if [ -e "$MANIFEST" ]; then
    printf '安装记录: %s\n' "$MANIFEST"
  else
    printf '安装记录: 不存在（%s）\n' "$MANIFEST"
    printf '这是 v2.2.0 之前安装的形态。恢复前需要用 --adopt-backup 显式指认真备份。\n'
  fi
  printf '入口现状:\n'
  describe_entry claude
  describe_entry claude-official
  describe_entry claude-cc
  describe_entry claude-guard
  printf '\n本次为只读检查，没有修改任何文件。\n'
  exit 0
fi

[ -e "$MANIFEST" ] || fail_closed "找不到安装记录: $MANIFEST"
jq empty "$MANIFEST" >/dev/null 2>&1 || fail_closed "安装记录不是有效 JSON: $MANIFEST"

# 结构与路径约束要在任何文件动作之前跑。卸载器按 entries[].path 删文件、按
# original.mode 执行 chmod，这些值不受约束就意味着一个被改过的 manifest 能让它删掉
# 前缀之外的文件，或者在第二遍中途因 chmod 失败而留下「恢复一半」。
validate_manifest "$MANIFEST" "$BIN_DIR" || fail_closed "安装记录未通过校验: $MANIFEST"

# 所有改动先落在候选 manifest 上，全部校验通过之后才在执行阶段一次性提交。
# --dry-run 只读候选，绝不替换正式文件。
CANDIDATE="$MANIFEST.candidate.$$"
# 第二遍读哪一份：apply 模式下候选已被提交成正式 manifest，dry-run 下仍是候选。
ACTIVE_MANIFEST="$CANDIDATE"
cleanup_candidate() { rm -f "$CANDIDATE"; }
trap cleanup_candidate EXIT
cp "$MANIFEST" "$CANDIDATE"

# --adopt-backup：把用户显式指认的文件写进候选 manifest 作为该入口的原始备份。
adopt_backup() {
  local spec="$1"
  local name backup digest mode tmp

  name="${spec%%=*}"
  backup="${spec#*=}"

  manifest_has_entry "$CANDIDATE" "$name" ||
    fail_closed "安装记录里没有这个入口，无法指认备份: $name"
  [ -f "$backup" ] || fail_closed "指认的备份不存在或不是普通文件: $backup"
  if is_guard_shim "$backup"; then
    fail_closed "指认的备份内容是 Guard shim，不是原始入口: $backup"
  fi
  case "$backup" in
    /*) ;;
    *) fail_closed "指认的备份必须是绝对路径: $backup" ;;
  esac

  digest="$(sha256_file "$backup")" || exit 14
  mode="$(file_mode "$backup")" || exit 14
  tmp="$CANDIDATE.tmp.$$"
  jq --arg n "$name" --arg b "$backup" --arg d "$digest" --arg m "$mode" \
    '.entries |= map(
       if .name == $n
       then .original = {state: "file", sha256: $d, mode: $m, backup_path: $b}
       else . end)' "$CANDIDATE" >"$tmp"
  mv "$tmp" "$CANDIDATE"
  printf '已指认备份: %s -> %s\n' "$name" "$backup"
}

while IFS= read -r spec; do
  [ -n "$spec" ] || continue
  adopt_backup "$spec"
done <<EOF
$ADOPTIONS
EOF

# adoption 之后再校验一次：指认动作本身也可能把 manifest 写成不合法的形态。
validate_manifest "$CANDIDATE" "$BIN_DIR" || fail_closed "指认备份后的安装记录未通过校验"

# ---- 第一遍：只校验，不动文件。全部通过之后才进入第二遍执行 ----

# 这个 entry 当前是否已经等于记录里的原始状态。上一次卸载被打断后重跑时，前面
# 已恢复的 entry 会落在这个分支，否则重试会把它们当成「用户手工改过」而卡死。
# 读 $ACTIVE_MANIFEST 而不是 $CANDIDATE：候选在执行阶段开始前就被 mv 成正式
# manifest 了，继续读候选会在 apply 模式下拿不到文件，这条分支就永远不成立。
entry_already_restored() {
  local name="$1" path="$2"
  local state

  state="$(manifest_entry_field "$ACTIVE_MANIFEST" "$name" original.state)"
  case "$state" in
    absent)
      [ ! -e "$path" ] && [ ! -L "$path" ]
      ;;
    symlink|dangling-symlink)
      [ -L "$path" ] &&
        [ "$(readlink "$path")" = "$(manifest_entry_field "$ACTIVE_MANIFEST" "$name" original.symlink_target)" ]
      ;;
    file)
      [ -f "$path" ] && [ ! -L "$path" ] &&
        [ "$(sha256_file "$path")" = "$(manifest_entry_field "$ACTIVE_MANIFEST" "$name" original.sha256)" ]
      ;;
    *)
      return 1
      ;;
  esac
}

# 只验证这个 mode 在本平台上 chmod 能接受，绝不碰用户的文件。
# 上一版直接对真实备份 chmod，结果 --dry-run 会把备份权限从 755 改成 600，备份路径
# 若是 symlink 还会顺着改到外部文件上——「预演」本身成了副作用。
mode_is_applicable() {
  local mode="$1"
  local probe

  probe="$(mktemp)" || return 1
  if chmod "$mode" "$probe" 2>/dev/null; then
    rm -f "$probe"
    return 0
  fi
  rm -f "$probe"
  return 1
}

check_entry() {
  local name="$1"
  local path artifact state recorded_sha current_sha backup backup_sha

  path="$(manifest_entry_field "$CANDIDATE" "$name" path)"
  [ -n "$path" ] || fail_closed "安装记录里的条目缺少 path: $name"
  artifact="$(manifest_entry_field "$CANDIDATE" "$name" artifact)"

  recorded_sha="$(manifest_entry_field "$CANDIDATE" "$name" artifact_sha256)"
  case "$(entry_state "$path")" in
    absent)
      # 入口已经不在了，恢复时按 original 处理即可，这里没有可校验的对象。
      ;;
    symlink|dangling-symlink)
      entry_already_restored "$name" "$path" ||
        fail_closed "当前入口是 symlink，不是我们安装的内容，拒绝改动: $path"
      ;;
    file)
      current_sha="$(sha256_file "$path")" || exit 14
      if [ "$current_sha" = "$recorded_sha" ]; then
        :
      elif entry_already_restored "$name" "$path"; then
        # 上一次卸载在这个 entry 之后被打断，这一份已经是恢复好的原件，允许重跑。
        :
      elif [ "$artifact" = shim ] &&
           is_guard_shim_for "$path" "$BIN_DIR/claude-guard"; then
        # 严格版判定，且只对 shim 类入口开放。binary 类（claude-guard / claude-cc）
        # 只认记录摘要——否则把 claude-guard 换成一个合法 shim 就能骗过卸载器。
        :
      else
        fail_closed "当前入口既不是安装时的内容也不是可识别的已恢复状态，可能已被手工修改，拒绝改动: $path"
      fi
      ;;
  esac

  state="$(manifest_entry_field "$CANDIDATE" "$name" original.state)"
  [ "$state" = file ] || return 0

  backup="$(manifest_entry_field "$CANDIDATE" "$name" original.backup_path)"
  [ -n "$backup" ] || fail_closed "安装记录声明有备份却没有 backup_path: $name"
  # 备份必须是普通文件而不是 symlink：顺着 symlink 写会改到前缀之外的文件上。
  if [ -L "$backup" ] || [ ! -f "$backup" ]; then
    if entry_already_restored "$name" "$path"; then
      # 重跑场景：这个 entry 已经恢复过，备份也已经被回收，属于正常。
      return 0
    fi
    fail_closed "安装记录指向的备份不存在或不是普通文件: $backup"
  fi
  # 这一条正是 issue #15 留下的现场：备份文件里躺着的是 Guard shim。
  if is_guard_shim "$backup"; then
    fail_closed "备份内容是 Guard shim 而不是原始入口，拒绝用它覆盖: $backup"
  fi
  backup_sha="$(sha256_file "$backup")" || exit 14
  if [ "$backup_sha" != "$(manifest_entry_field "$CANDIDATE" "$name" original.sha256)" ]; then
    fail_closed "备份内容与安装时记录的摘要不符: $backup"
  fi
  mode_is_applicable "$(manifest_entry_field "$CANDIDATE" "$name" original.mode)" ||
    fail_closed "安装记录里的 original.mode 在本平台无法应用: $name"
}

names="$(jq -r '.entries[].name' "$CANDIDATE")"
while IFS= read -r name; do
  [ -n "$name" ] || continue
  check_entry "$name"
done <<EOF
$names
EOF

# ---- 第二遍：执行 ----

act() {
  if [ "$DRY_RUN" -eq 1 ]; then
    printf '  [dry-run] %s\n' "$1"
    return 0
  fi
  return 1
}

# 每个 entry 的替换都先在同目录写 staging，再 mv 原子换上去。跨 entry 做不到全局
# 原子，但至少单个入口不会停在半写状态，而且整体可以安全重跑：已恢复的 entry 会被
# entry_already_restored 认出来并跳过。
#
# 顺序上 claude-guard 排到最后：shim 指向它，先删 guard 会让还没恢复的 shim 变成
# 指向不存在文件的死入口。
restore_entry() {
  local name="$1"
  local path state target backup mode staging

  path="$(manifest_entry_field "$ACTIVE_MANIFEST" "$name" path)"
  state="$(manifest_entry_field "$ACTIVE_MANIFEST" "$name" original.state)"

  if [ "$DRY_RUN" -eq 0 ] && entry_already_restored "$name" "$path"; then
    printf '已是原始状态，跳过: %s\n' "$path"
    return 0
  fi

  staging="$path.claude-guard-restore.$$"
  case "$state" in
    absent)
      if act "移除 $path"; then return 0; fi
      rm -f "$path"
      printf '已移除: %s\n' "$path"
      ;;
    symlink|dangling-symlink)
      target="$(manifest_entry_field "$ACTIVE_MANIFEST" "$name" original.symlink_target)"
      if act "把 $path 恢复为指向 $target 的 symlink"; then return 0; fi
      # 必须用 ln -s 重建。当初就是因为 cp -p 会把 symlink 展平成普通文件，才改成
      # 只在 manifest 里记 target。悬空 symlink 同样能这样重建。
      rm -f "$staging"
      ln -s "$target" "$staging" || fail_closed "无法创建 symlink: $staging"
      mv "$staging" "$path" || { rm -f "$staging"; fail_closed "无法就位: $path"; }
      printf '已恢复 symlink: %s -> %s\n' "$path" "$target"
      ;;
    file)
      backup="$(manifest_entry_field "$ACTIVE_MANIFEST" "$name" original.backup_path)"
      mode="$(manifest_entry_field "$ACTIVE_MANIFEST" "$name" original.mode)"
      # ${path} 的花括号不能省：bash 3.2 会把紧随其后的全角字符的首字节吞进变量名，
      # 于是 set -u 报 "path?: unbound variable"。bash 5 下没有这个问题。
      if act "用 $backup 恢复 ${path}（权限 ${mode}）"; then return 0; fi
      rm -f "$staging"
      cp -p "$backup" "$staging" || { rm -f "$staging"; fail_closed "无法写入暂存文件: $staging"; }
      chmod "$mode" "$staging" || { rm -f "$staging"; fail_closed "无法设置权限: $staging"; }
      mv "$staging" "$path" || { rm -f "$staging"; fail_closed "无法就位: $path"; }
      printf '已恢复: %s\n' "$path"
      ;;
    *)
      fail_closed "安装记录里的 original.state 不可识别: $name=${state:-empty}"
      ;;
  esac
}

# 备份统一在所有 entry 都成功之后再回收。中途失败时备份必须还在，否则重跑就没有
# 可用的原件了。只回收我们自己创建的那一份——--adopt-backup 指认的是用户既有的
# 文件，「不自动删除历史备份」对它同样成立。
reclaim_backups() {
  local name path backup

  while IFS= read -r name; do
    [ -n "$name" ] || continue
    path="$(manifest_entry_field "$ACTIVE_MANIFEST" "$name" path)"
    [ "$(manifest_entry_field "$ACTIVE_MANIFEST" "$name" original.state)" = file ] || continue
    backup="$(manifest_entry_field "$ACTIVE_MANIFEST" "$name" original.backup_path)"
    [ "$backup" = "$(backup_path_for "$path")" ] || continue
    rm -f "$backup"
  done <<INNER
$names
INNER
}

# 全部校验通过，这里是唯一的提交点。dry-run 不提交，候选由 EXIT trap 清掉。
if [ "$DRY_RUN" -eq 0 ]; then
  mv "$CANDIDATE" "$MANIFEST" || fail_closed "无法提交安装记录: $MANIFEST"
  trap - EXIT
  ACTIVE_MANIFEST="$MANIFEST"
fi

printf '前缀: %s\n' "$PREFIX"
# claude-guard 排到最后。shim 指向它，先删 guard 会把还没恢复的 shim 变成指向不存在
# 文件的死入口——那正是「恢复一半」里最难收拾的形态。
while IFS= read -r name; do
  [ -n "$name" ] || continue
  [ "$name" = claude-guard ] && continue
  restore_entry "$name"
done <<EOF
$names
EOF
while IFS= read -r name; do
  [ "$name" = claude-guard ] || continue
  restore_entry "$name"
done <<EOF
$names
EOF

# 到这里所有 entry 都已就位，备份才可以回收。中途失败时它们必须还在，否则重跑就没有
# 可用的原件了。
if [ "$DRY_RUN" -eq 0 ]; then
  reclaim_backups
fi

if act "删除安装记录 $MANIFEST"; then
  :
else
  rm -f "$MANIFEST"
  rmdir "$(dirname "$MANIFEST")" 2>/dev/null || true
  printf '已删除安装记录: %s\n' "$MANIFEST"
fi

# 历史备份一律保留。判断哪一个是真原件需要人来看，脚本不替用户删。
leftovers=''
for name in claude claude-official claude-cc claude-guard; do
  while IFS= read -r legacy; do
    [ -n "$legacy" ] || continue
    leftovers="$leftovers  $legacy"$'\n'
  done <<EOF
$(list_legacy_backups "$name")
EOF
done
if [ -n "$leftovers" ]; then
  printf '\n以下历史备份未被删除，请自行确认后处理：\n'
  printf '%s' "$leftovers"
fi

if [ "$DRY_RUN" -eq 1 ]; then
  printf '\n本次为 dry-run，没有修改任何文件。\n'
else
  printf '\n卸载完成。\n'
fi
