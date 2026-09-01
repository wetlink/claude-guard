# shellcheck shell=bash
# 入口生命周期的共享逻辑：Guard shim 判定、原入口状态采集、manifest 读写。
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

# 判定一个文件是否 Guard shim。不依赖 manifest：先用标记行或结构做廉价筛选，再按
# 从文件里读出的 guard 路径重建正文做逐字节比对。
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

  if [ "$(cat "$file")" = "$(shim_body "$guard")" ]; then
    return 0
  fi
  if [ "$(cat "$file")" = "$(legacy_shim_body "$guard")" ]; then
    return 0
  fi
  return 1
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

# 采集原入口状态并在必要时备份，输出一个 JSON 对象。
# 只有普通文件才复制；symlink 与悬空 symlink 一律只记 target——cp -p 会把 symlink
# 展平成普通文件，链接关系就永久丢了。
capture_original() {
  local path="$1"
  local state backup digest mode

  state="$(entry_state "$path")"
  case "$state" in
    absent)
      jq -n --arg s "$state" '{state: $s}'
      ;;
    symlink|dangling-symlink)
      jq -n --arg s "$state" --arg t "$(readlink "$path")" \
        '{state: $s, symlink_target: $t}'
      ;;
    file)
      backup="$(backup_path_for "$path")"
      if [ -e "$backup" ] || [ -L "$backup" ]; then
        printf '备份文件已存在，拒绝覆盖: %s\n' "$backup" >&2
        return 1
      fi
      cp -p "$path" "$backup"
      digest="$(sha256_file "$path")" || return 1
      mode="$(file_mode "$path")" || return 1
      printf '已备份: %s\n' "$backup" >&2
      jq -n --arg s "$state" --arg d "$digest" --arg m "$mode" --arg b "$backup" \
        '{state: $s, sha256: $d, mode: $m, backup_path: $b}'
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
manifest_record() {
  local manifest="$1" name="$2" path="$3" artifact="$4" version="$5"
  local artifact_source="$6"
  local digest now original tmp

  digest="$(sha256_file "$artifact_source")" || return 1
  now="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  tmp="$manifest.tmp.$$"

  if manifest_has_entry "$manifest" "$name"; then
    jq --arg n "$name" --arg d "$digest" --arg v "$version" --arg t "$now" \
      '.entries |= map(
         if .name == $n
         then .artifact_sha256 = $d | .guard_version = $v | .installed_at = $t
         else . end)' "$manifest" >"$tmp"
  else
    original="$(capture_original "$path")" || return 1
    jq --arg n "$name" --arg p "$path" --arg a "$artifact" --arg d "$digest" \
       --arg v "$version" --arg t "$now" --argjson o "$original" \
      '.entries += [{
         name: $n, path: $p, artifact: $a, artifact_sha256: $d,
         guard_version: $v, installed_at: $t, original: $o
       }]' "$manifest" >"$tmp"
  fi

  mv "$tmp" "$manifest"
}
