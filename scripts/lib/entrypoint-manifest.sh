# shellcheck shell=bash
# 入口生命周期的共享逻辑：Guard shim 判定、原入口状态采集、manifest 读写与校验。
# 由 scripts/install*.sh 与 scripts/uninstall.sh 共同 source。
#
# 本文件刻意不设 set -euo pipefail：选项由 source 它的脚本自行设置，一个被 source
# 的文件不应该改变调用方的 shell 选项。
#
# sha256_file 与 require_cmd 与 bin/claude-guard、bin/claude-cc 中的同名函数逐字
# 相同。项目没有 lib 层且 CONTRIBUTING.md 要求依赖极简，重复一份优于引入加载机制。

CLAUDE_GUARD_SHIM_MARKER='# claude-guard-shim 1'
CLAUDE_GUARD_BACKUP_EXT='claude-guard-backup'
CLAUDE_GUARD_MANIFEST_VERSION='1'
CLAUDE_GUARD_ENTRY_NAMES='claude claude-official claude-cc claude-guard'

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    printf '缺少依赖命令: %s\n' "$1" >&2
    case "$1" in
      curl) printf '安装建议: macOS 通常自带 curl；如缺失可执行 brew install curl\n' >&2 ;;
      jq) printf '安装建议: brew install jq\n' >&2 ;;
    esac
    exit 127
  fi
}

sha256_file() {
  local file="$1"

  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$file" | awk '{print $1}'
    return 0
  fi
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$file" | awk '{print $1}'
    return 0
  fi

  printf '缺少 SHA-256 校验工具；需要 shasum 或 sha256sum。\n' >&2
  return 1
}

# 八进制权限位。BSD stat（macOS）与 GNU stat（Linux）的选项不通用，两个都试。
file_mode() {
  local path="$1"
  local mode

  if mode="$(stat -f '%Lp' "$path" 2>/dev/null)"; then
    printf '%s\n' "$mode"
    return 0
  fi
  if mode="$(stat -c '%a' "$path" 2>/dev/null)"; then
    printf '%s\n' "$mode"
    return 0
  fi

  printf '无法读取文件权限位: %s\n' "$path" >&2
  return 1
}

manifest_path() {
  printf '%s/share/claude-guard/entrypoints.json\n' "$1"
}

backup_path_for() {
  printf '%s.%s\n' "$1" "$CLAUDE_GUARD_BACKUP_EXT"
}

staging_backup_path_for() {
  printf '%s.%s.staging.%s\n' "$1" "$CLAUDE_GUARD_BACKUP_EXT" "$$"
}

# 入口的四种形态。-L 必须排在 -e 前面：悬空 symlink 的 [ -e ] 为假，先问 -e 会把
# 它误判成 absent，于是连备份都不做就被 install 覆盖掉。
entry_state() {
  local path="$1"

  if [ -L "$path" ]; then
    if [ -e "$path" ]; then
      printf 'symlink\n'
    else
      printf 'dangling-symlink\n'
    fi
    return 0
  fi
  if [ -e "$path" ]; then
    printf 'file\n'
    return 0
  fi
  printf 'absent\n'
}

# shim 正文由 guard 路径唯一决定，因此可以精确重建后比对，而不是模糊匹配。
shim_body() {
  printf '#!/usr/bin/env bash\n'
  printf '%s\n' "$CLAUDE_GUARD_SHIM_MARKER"
  printf 'set -euo pipefail\n'
  printf '\n'
  printf 'exec "%s" "$@"\n' "$1"
}

# v2.1.3 及更早的 shim 没有标记行，只有这 4 行。--inspect 必须能在没有 manifest 的
# 存量环境上工作，所以两种形态都要认。
legacy_shim_body() {
  printf '#!/usr/bin/env bash\n'
  printf 'set -euo pipefail\n'
  printf '\n'
  printf 'exec "%s" "$@"\n' "$1"
}

# 严格判定：文件是不是一个指向「指定 guard 路径」的 Guard shim。
# 卸载器决定「这个入口还是不是我们装的、可以覆盖」时必须用这个版本——只问「像不像
# 某个 shim」会把指向别处 guard 的 shim 也放进来，那是别人的入口，不是我们的。
is_guard_shim_for() {
  local file="$1" guard="$2"

  [ -f "$file" ] || return 1
  [ -L "$file" ] && return 1

  if [ "$(cat "$file")" = "$(shim_body "$guard")" ]; then
    return 0
  fi
  if [ "$(cat "$file")" = "$(legacy_shim_body "$guard")" ]; then
    return 0
  fi
  return 1
}

# 宽松判定：文件是不是某个 Guard shim（不限 guard 路径）。
# 只用于两处「宁可误报也不能漏报」的场景：--inspect 的诊断输出，以及「这份备份里
# 躺着的其实是一个 shim」的拦截。两者都不会据此覆盖或删除入口文件。
is_guard_shim() {
  local file="$1"
  local guard

  [ -f "$file" ] || return 1
  [ -L "$file" ] && return 1

  guard="$(sed -n 's/^exec "\(.*\)" "\$@"$/\1/p' "$file" | head -1)"
  [ -n "$guard" ] || return 1
  case "$guard" in
    */claude-guard) ;;
    *) return 1 ;;
  esac

  is_guard_shim_for "$file" "$guard"
}

manifest_init() {
  local manifest="$1"
  local dir

  dir="$(dirname "$manifest")"
  mkdir -p "$dir"
  if [ ! -e "$manifest" ]; then
    jq -n --arg v "$CLAUDE_GUARD_MANIFEST_VERSION" \
      '{manifest_version: ($v | tonumber), entries: []}' >"$manifest"
  fi
}

manifest_has_entry() {
  jq -e --arg n "$2" '[.entries[] | select(.name == $n)] | length > 0' \
    "$1" >/dev/null 2>&1
}

manifest_entry_field() {
  jq -r --arg n "$2" --arg f "$3" \
    'first(.entries[] | select(.name == $n)) | getpath($f | split(".")) // empty' \
    "$1"
}

# manifest 的结构与路径约束。必须在任何文件动作之前跑一次。
#
# 卸载器会按 entries[].path 删除文件、按 original.mode 执行 chmod。这些值一旦不受
# 约束，一个被改过的 manifest 就能让卸载器删掉前缀之外的文件，或者在第二遍中途因为
# chmod 失败而留下「恢复一半」的现场。校验放在第一遍之前，坏数据就永远走不到执行。
validate_manifest() {
  local manifest="$1" bin_dir="$2"
  local problems

  problems="$(jq -r --arg bin "$bin_dir" \
      --arg v "$CLAUDE_GUARD_MANIFEST_VERSION" \
      --arg names "$CLAUDE_GUARD_ENTRY_NAMES" '
    def hex64: type == "string" and test("^[0-9a-f]{64}$");
    def octal: type == "string" and test("^[0-7]{3,4}$");
    ($names | split(" ")) as $allowed
    | (if (.manifest_version | tostring) != $v
         then ["manifest_version 不受支持: \(.manifest_version)"] else [] end)
    + (if (.entries | type) != "array" then ["entries 不是数组"] else [] end)
    + [ (.entries // []) | group_by(.name)[] | select(length > 1)
        | "entry 名称重复: \(.[0].name)" ]
    + [ (.entries // [])[] as $e
        | ( if ($allowed | index($e.name)) == null
              then "entry 名称不在允许列表: \($e.name)" else empty end
          , if $e.path != ($bin + "/" + ($e.name | tostring))
              then "entry path 必须等于 \($bin)/\($e.name)，实际: \($e.path)" else empty end
          , if ($allowed | length) > 0 and (["shim","binary"] | index($e.artifact)) == null
              then "artifact 取值非法: \($e.name)=\($e.artifact)" else empty end
          , if ($e.artifact_sha256 | hex64) | not
              then "artifact_sha256 不是 64 位十六进制: \($e.name)" else empty end
          , if (["absent","file","symlink","dangling-symlink"] | index($e.original.state)) == null
              then "original.state 非法: \($e.name)=\($e.original.state)" else empty end
          , if $e.original.state == "file" and (($e.original.sha256 | hex64) | not)
              then "original.sha256 非法: \($e.name)" else empty end
          , if $e.original.state == "file" and (($e.original.mode | octal) | not)
              then "original.mode 非法: \($e.name)=\($e.original.mode)" else empty end
          , if $e.original.state == "file"
                 and ((($e.original.backup_path | type) != "string")
                      or (($e.original.backup_path | startswith("/")) | not))
              then "original.backup_path 必须是绝对路径: \($e.name)" else empty end
          , if (["symlink","dangling-symlink"] | index($e.original.state)) != null
                 and ((($e.original.symlink_target | type) != "string")
                      or ($e.original.symlink_target == ""))
              then "original.symlink_target 为空: \($e.name)" else empty end
          ) ]
    | .[]
  ' "$manifest" 2>&1)"

  [ -z "$problems" ] || {
    printf '%s\n' "$problems" >&2
    return 1
  }
  return 0
}

# 采集原入口状态，把 JSON 写进 $2；普通文件的备份先落到 staging 路径，由
# manifest_record 在 manifest 提交成功之后才改名到正式位置。
#
# 不用命令替换返回 JSON：那会跑在子 shell 里，staging 路径没法回传给调用方。
#
# 只有普通文件才复制；symlink 与悬空 symlink 一律只记 target——cp -p 会把 symlink
# 展平成普通文件，链接关系就永久丢了。
capture_original() {
  local path="$1" out="$2"
  local state backup staging source digest mode

  CLAUDE_GUARD_PENDING_SRC=''
  CLAUDE_GUARD_PENDING_DST=''

  state="$(entry_state "$path")"
  case "$state" in
    absent)
      jq -n --arg s "$state" '{state: $s}' >"$out"
      ;;
    symlink|dangling-symlink)
      jq -n --arg s "$state" --arg t "$(readlink "$path")" \
        '{state: $s, symlink_target: $t}' >"$out"
      ;;
    file)
      backup="$(backup_path_for "$path")"
      if [ -e "$backup" ] || [ -L "$backup" ]; then
        # 正式备份已存在但 manifest 里没有这个条目，只可能是上一次安装在
        # 「备份已改名、manifest 尚未提交」这一瞬间被打断。此时正式备份的内容按
        # 定义就是原始入口，直接复用即可——否则每次重试都会撞上「备份已存在」而
        # 永久卡死，用户没有任何出路。
        if is_guard_shim "$backup"; then
          printf '备份文件内容是 Guard shim，无法当作原始入口: %s\n' "$backup" >&2
          return 1
        fi
        if ! is_guard_shim_for "$path" "$(dirname "$path")/claude-guard" &&
           [ "$(sha256_file "$path")" != "$(sha256_file "$backup")" ]; then
          printf '备份文件已存在且与当前入口不一致，请先人工确认: %s\n' "$backup" >&2
          return 1
        fi
        printf '复用上次中断留下的备份: %s\n' "$backup" >&2
        source="$backup"
      else
        staging="$(staging_backup_path_for "$path")"
        cp -p "$path" "$staging" || return 1
        CLAUDE_GUARD_PENDING_SRC="$staging"
        CLAUDE_GUARD_PENDING_DST="$backup"
        source="$staging"
      fi
      # source 必须是一个确实存在的文件。sha256_file 走 shasum | awk，awk 会把
      # shasum 的失败状态吞掉，对不存在的文件返回 0 且输出为空——拿它当摘要会写出
      # 一条通不过 validate_manifest 的记录，而且是在安装阶段悄悄写进去的。
      digest="$(sha256_file "$source")" || return 1
      mode="$(file_mode "$source")" || return 1
      [ -n "$digest" ] || { printf '无法计算备份摘要: %s\n' "$source" >&2; return 1; }
      jq -n --arg s "$state" --arg d "$digest" --arg m "$mode" --arg b "$backup" \
        '{state: $s, sha256: $d, mode: $m, backup_path: $b}' >"$out"
      ;;
  esac
}

# 记录一次安装。必须在覆盖入口之前调用，否则 capture_original 看到的已经是我们
# 自己写进去的内容。artifact_source 是「即将被安装的那份文件」，artifact_sha256
# 取自它而不是 path——调用时 path 上躺着的还是原入口。
#
# 核心不变式：original 一旦写入就永不覆盖。同版本重装与跨版本升级都只刷新
# artifact_sha256 / guard_version / installed_at。issue #15 的根因正是旧实现在
# 版本号变化时重新采集了 original，于是把已经装好的 Guard shim 当成原始入口备份。
#
# 提交顺序：备份先落 staging → 写候选 manifest → 改名备份到正式位置 → 提交
# manifest。任何一步失败都回滚本次产生的中间产物，绝不留下「备份在、条目不在」。
manifest_record() {
  local manifest="$1" name="$2" path="$3" artifact="$4" version="$5"
  local artifact_source="$6"
  local digest now tmp orig_json

  digest="$(sha256_file "$artifact_source")" || return 1
  now="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  tmp="$manifest.tmp.$$"
  orig_json="$manifest.orig.$$"
  CLAUDE_GUARD_PENDING_SRC=''
  CLAUDE_GUARD_PENDING_DST=''

  if manifest_has_entry "$manifest" "$name"; then
    if ! jq --arg n "$name" --arg d "$digest" --arg v "$version" --arg t "$now" \
        '.entries |= map(
           if .name == $n
           then .artifact_sha256 = $d | .guard_version = $v | .installed_at = $t
           else . end)' "$manifest" >"$tmp"; then
      rm -f "$tmp"
      return 1
    fi
  else
    if ! capture_original "$path" "$orig_json"; then
      rm -f "$orig_json" "$CLAUDE_GUARD_PENDING_SRC"
      return 1
    fi
    if ! jq --arg n "$name" --arg p "$path" --arg a "$artifact" --arg d "$digest" \
         --arg v "$version" --arg t "$now" --slurpfile o "$orig_json" \
        '.entries += [{
           name: $n, path: $p, artifact: $a, artifact_sha256: $d,
           guard_version: $v, installed_at: $t, original: $o[0]
         }]' "$manifest" >"$tmp"; then
      rm -f "$tmp" "$orig_json" "$CLAUDE_GUARD_PENDING_SRC"
      return 1
    fi
    rm -f "$orig_json"
  fi

  if [ -n "$CLAUDE_GUARD_PENDING_SRC" ]; then
    if ! mv "$CLAUDE_GUARD_PENDING_SRC" "$CLAUDE_GUARD_PENDING_DST"; then
      rm -f "$tmp" "$CLAUDE_GUARD_PENDING_SRC"
      return 1
    fi
    printf '已备份: %s\n' "$CLAUDE_GUARD_PENDING_DST" >&2
  fi

  if ! mv "$tmp" "$manifest"; then
    # manifest 没提交成功，就把这一步刚放好的正式备份撤回来，不留孤儿。
    if [ -n "$CLAUDE_GUARD_PENDING_DST" ]; then
      rm -f "$CLAUDE_GUARD_PENDING_DST"
    fi
    rm -f "$tmp"
    return 1
  fi
}
