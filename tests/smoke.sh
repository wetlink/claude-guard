#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

bash -n "$ROOT_DIR/bin/claude-guard"
bash -n "$ROOT_DIR/bin/claude-cc"
bash -n "$ROOT_DIR/scripts/install.sh"
bash -n "$ROOT_DIR/scripts/install-entrypoint-shims.sh"
bash -n "$ROOT_DIR/scripts/install-cc-entrypoint.sh"
bash -n "$ROOT_DIR/scripts/uninstall.sh"
bash -n "$ROOT_DIR/scripts/lib/entrypoint-manifest.sh"

# bash 3.2（macOS 系统自带）会把紧跟在 $var 后面的多字节字符的首字节吞进变量名，
# 于是 set -u 下报出 "path?: unbound variable" 这种谁也看不懂的错。bash 5 没有这个
# 行为，ShellCheck 也不报，因此只有跑在 macOS 上才会炸——本仓库几乎全是中文提示语，
# 这个坑一碰一个准。写成 ${var} 即可。
# 注释里怎么写都不影响运行，排除掉。grep 的输出是「文件:行号:内容」，所以注释的
# 判断要跨过前两段，不能简单地锚在行首。
if git -C "$ROOT_DIR" ls-files 'bin/*' 'scripts/*.sh' 'tests/*.sh' |
    xargs grep -n '\$[A-Za-z_][A-Za-z0-9_]*[^ -~]' 2>/dev/null |
    grep -vE '^[^:]*:[0-9]+:[[:space:]]*#'; then
  # shellcheck disable=SC2016  # 提示文本本身要原样显示 $变量 与 ${变量} 两种写法
  printf '上列位置的 $变量 后面紧跟多字节字符，在 bash 3.2 下会被吞进变量名，请改写成 ${变量}。\n' >&2
  exit 1
fi

expected_version="$(tr -d '[:space:]' < "$ROOT_DIR/VERSION")"
version="$("$ROOT_DIR/bin/claude-guard" --version)"
if [ "$version" != "claude-guard $expected_version" ]; then
  printf 'unexpected version: %s\n' "$version" >&2
  exit 1
fi

"$ROOT_DIR/bin/claude-guard" --help >/dev/null

CLAUDE_GUARD_PREFIX="$TMP_DIR/prefix" "$ROOT_DIR/scripts/install-entrypoint-shims.sh" >/tmp/claude-guard-install.out 2>&1
grep -q '入口已收敛' /tmp/claude-guard-install.out
grep -q 'exec "'"$TMP_DIR"'/prefix/bin/claude-guard" "$@"' "$TMP_DIR/prefix/bin/claude"
grep -q 'exec "'"$TMP_DIR"'/prefix/bin/claude-guard" "$@"' "$TMP_DIR/prefix/bin/claude-official"

CLAUDE_GUARD_PREFIX="$TMP_DIR/cc-prefix" "$ROOT_DIR/scripts/install-cc-entrypoint.sh" >/tmp/claude-cc-install.out 2>&1
grep -q 'CC Switch 入口' /tmp/claude-cc-install.out
cmp "$ROOT_DIR/bin/claude-cc" "$TMP_DIR/cc-prefix/bin/claude-cc"

if CLAUDE_GUARD_CONFIG="$TMP_DIR/missing.json" "$ROOT_DIR/bin/claude-guard" >/tmp/claude-guard-test.out 2>&1; then
  printf 'missing config test unexpectedly passed\n' >&2
  exit 1
fi
grep -q 'IP 安全配置不存在' /tmp/claude-guard-test.out

printf '{"command":"claude","allowed_ips":["1.2.3.4"]}\n' > "$TMP_DIR/relative-command.json"
if CLAUDE_GUARD_CONFIG="$TMP_DIR/relative-command.json" "$ROOT_DIR/bin/claude-guard" >/tmp/claude-guard-test.out 2>&1; then
  printf 'relative command test unexpectedly passed\n' >&2
  exit 1
fi
grep -q '必须是原始 Claude CLI 的绝对路径' /tmp/claude-guard-test.out

# shellcheck disable=SC2016  # 指纹 fixture 必须写入字面量 ${n} / ${r}，展开后就不再是被检测的那段内容
printf '#!/usr/bin/env bash\n# Asia/Shanghai\n# Asia/Urumqi\n# Today${n}s date is ${r}.\nprintf fake-claude\\n\n' > "$TMP_DIR/fingerprint-claude"
chmod +x "$TMP_DIR/fingerprint-claude"
printf '{"command":"%s","allowed_ips":["1.2.3.4"]}\n' "$TMP_DIR/fingerprint-claude" > "$TMP_DIR/fingerprint-config.json"
cat >"$TMP_DIR/settings.json" <<'EOF'
{
  "disableAgentView": true,
  "disableRemoteControl": true,
  "disableDeepLinkRegistration": "disable",
  "disableAllHooks": true,
  "disableWorkflows": true,
  "env": {
    "DISABLE_UPDATES": "1",
    "CLAUDE_CODE_DISABLE_AGENT_VIEW": "1",
    "CLAUDE_CODE_DISABLE_CRON": "1",
    "CLAUDE_CODE_DISABLE_BG_EXIT_HANDOFF": "1",
    "CLAUDE_DISABLE_ADOPT": "1",
    "CLAUDE_CODE_DISABLE_WORKFLOWS": "1",
    "CLAUDE_CODE_MCP_AUTO_BACKGROUND_MS": "0",
    "CLAUDE_CODE_MAX_SUBAGENT_SPAWN_DEPTH": "1",
    "CLAUDE_CODE_MAX_CONCURRENT_SUBAGENTS": "3"
  }
}
EOF
printf 'fake ca\n' > "$TMP_DIR/cert.pem"

if ANTHROPIC_BASE_URL="http://127.0.0.1:15721" \
  CLAUDE_GUARD_CONFIG="$TMP_DIR/fingerprint-config.json" \
  CLAUDE_GUARD_SETTINGS="$TMP_DIR/settings.json" \
  CLAUDE_GUARD_CA_CERT="$TMP_DIR/cert.pem" \
  "$ROOT_DIR/bin/claude-guard" --precheck-only >/tmp/claude-guard-test.out 2>&1; then
  printf 'active fingerprint tripwire test unexpectedly passed\n' >&2
  exit 1
fi
grep -q '客户端指纹预检失败' /tmp/claude-guard-test.out

if CLAUDE_GUARD_FINGERPRINT_MODE=strict \
  CLAUDE_GUARD_CONFIG="$TMP_DIR/fingerprint-config.json" \
  CLAUDE_GUARD_SETTINGS="$TMP_DIR/settings.json" \
  CLAUDE_GUARD_CA_CERT="$TMP_DIR/cert.pem" \
  "$ROOT_DIR/bin/claude-guard" --precheck-only >/tmp/claude-guard-test.out 2>&1; then
  printf 'strict fingerprint tripwire test unexpectedly passed\n' >&2
  exit 1
fi
grep -q 'strict 模式拒绝启动' /tmp/claude-guard-test.out

mkdir -p "$TMP_DIR/npm/@anthropic-ai/claude-code/bin" "$TMP_DIR/npm/@anthropic-ai/claude-code-darwin-arm64"
printf '#!/usr/bin/env bash\nprintf wrapper\\n\n' > "$TMP_DIR/npm/@anthropic-ai/claude-code/bin/claude.exe"
# shellcheck disable=SC2016  # 指纹 fixture 必须写入字面量 ${n} / ${r}，展开后就不再是被检测的那段内容
printf '#!/usr/bin/env bash\n# Asia/Shanghai\n# Asia/Urumqi\n# Today${n}s date is ${r}.\nprintf platform\\n\n' > "$TMP_DIR/npm/@anthropic-ai/claude-code-darwin-arm64/claude"
chmod +x "$TMP_DIR/npm/@anthropic-ai/claude-code/bin/claude.exe" "$TMP_DIR/npm/@anthropic-ai/claude-code-darwin-arm64/claude"
printf '{"command":"%s","allowed_ips":["1.2.3.4"]}\n' "$TMP_DIR/npm/@anthropic-ai/claude-code/bin/claude.exe" > "$TMP_DIR/wrapper-config.json"
if ANTHROPIC_BASE_URL="http://127.0.0.1:15721" \
  CLAUDE_GUARD_CONFIG="$TMP_DIR/wrapper-config.json" \
  CLAUDE_GUARD_SETTINGS="$TMP_DIR/settings.json" \
  CLAUDE_GUARD_CA_CERT="$TMP_DIR/cert.pem" \
  "$ROOT_DIR/bin/claude-guard" --precheck-only >/tmp/claude-guard-test.out 2>&1; then
  printf 'platform binary fingerprint tripwire test unexpectedly passed\n' >&2
  exit 1
fi
grep -q 'claude-code-darwin-arm64/claude' /tmp/claude-guard-test.out

mkdir -p "$TMP_DIR/bin"
cat > "$TMP_DIR/bin/curl" <<'EOF'
#!/usr/bin/env bash
args="$*"

if printf '%s' "$args" | grep -Eq '(^| )-6( |$)'; then
  exit 7
fi

if printf '%s' "$args" | grep -q 'https://ipinfo.io/ip'; then
  exit 28
fi

if printf '%s' "$args" | grep -q 'https://api.ipify.org'; then
  printf '203.0.113.10\n'
  exit 0
fi

if printf '%s' "$args" | grep -q 'https://api.anthropic.com/'; then
  {
    printf '* CONNECT api.anthropic.com:443 HTTP/1.1\n'
    printf '* CONNECT tunnel established\n'
    printf '* SSL certificate verify ok.\n'
    printf '*  issuer: C=US; O=Google Trust Services; CN=WE1\n'
  } >&2
  exit 0
fi

if printf '%s' "$args" | grep -q 'https://platform.claude.com/'; then
  {
    printf '* CONNECT platform.claude.com:443 HTTP/1.1\n'
    printf '* CONNECT tunnel established\n'
    printf '* SSL certificate verify ok.\n'
    printf '*  issuer: C=US; O=Let'\''s Encrypt; CN=YE1\n'
  } >&2
  exit 0
fi

exit 1
EOF
chmod +x "$TMP_DIR/bin/curl"
printf '{"command":"/bin/echo","allowed_ips":[],"allowed_cidrs":["203.0.113.0/24"]}\n' > "$TMP_DIR/cidr-config.json"
if ! PATH="$TMP_DIR/bin:$PATH" \
  CLAUDE_GUARD_CONFIG="$TMP_DIR/cidr-config.json" \
  CLAUDE_GUARD_SETTINGS="$TMP_DIR/settings.json" \
  CLAUDE_GUARD_CA_CERT="$TMP_DIR/cert.pem" \
  CLAUDE_GUARD_IP_CHECK_URLS="https://ipinfo.io/ip https://api.ipify.org" \
  CLAUDE_GUARD_ASSUME_YES=1 \
  "$ROOT_DIR/bin/claude-guard" --precheck-only >/tmp/claude-guard-test.out 2>&1; then
  cat /tmp/claude-guard-test.out >&2
  printf 'fallback IP/CIDR precheck test failed\n' >&2
  exit 1
fi
grep -q 'IP 检查通过：203.0.113.10' /tmp/claude-guard-test.out

printf 'smoke ok\n'
