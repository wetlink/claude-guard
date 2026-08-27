#!/usr/bin/env bash
set -euo pipefail

# 缺少 %{certs} 和 legacy verbose issuer 的 Schannel 构建无法完成 TLS/MITM 预检。
# curl 成功完成握手后仍无 issuer 才能确定是能力限制；curl 非零可能只是临时网络或证书
# 故障，必须保持普通失败语义并执行既定重试，不能误判为确定性不兼容。

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

mkdir -p "$TMP_DIR/home"

# 直接复用仓库里的官方 settings 示例：生命周期策略升级时它会一起更新，fixture 不会过期。
cp "$ROOT_DIR/config/official-settings-lifecycle.example.json" "$TMP_DIR/settings.json"

printf 'fake ca\n' >"$TMP_DIR/cert.pem"
printf '{"command":"/bin/echo","allowed_ips":["203.0.113.10"]}\n' >"$TMP_DIR/allowed.json"

# $1 = 假 curl 在 TLS 探测上的退出码
make_curl() {
  local dir="$TMP_DIR/bin-$1"
  mkdir -p "$dir"
  cat >"$dir/curl" <<EOF
#!/usr/bin/env bash
args="\$*"
printf '%s\n' "\$args" >>"\$HOME/curl.log"

if printf '%s' "\$args" | grep -Eq '(^| )-6( |\$)'; then
  exit 7
fi

if printf '%s' "\$args" | grep -q '/cdn-cgi/trace'; then
  printf 'fl=1f2\n'
  printf 'h=api.anthropic.com\n'
  printf 'ip=203.0.113.10\n'
  exit 0
fi

# Schannel 后端的 verbose 输出：隧道建好了，但没有 %{certs} 结构化块，
# 也没有 legacy verbose issuer 行。
if printf '%s' "\$args" | grep -q 'https://api.anthropic.com/'; then
  {
    printf '* CONNECT api.anthropic.com:443 HTTP/1.1\n'
    printf '* CONNECT tunnel established, response 200\n'
    printf '* schannel: disabled automatic use of client certificate\n'
    printf '* Connection #0 to host 127.0.0.1:7897 left intact\n'
  } >&2
  exit $1
fi

exit 1
EOF
  chmod +x "$dir/curl"
  printf '%s\n' "$dir"
}

run_precheck() {
  (
    cd "$TMP_DIR"
    HOME="$TMP_DIR/home" \
      USER="guard-test" \
      PATH="$1:$PATH" \
      LANG="en_US.UTF-8" \
      CLAUDE_GUARD_CONFIG="$TMP_DIR/allowed.json" \
      CLAUDE_GUARD_SETTINGS="$TMP_DIR/settings.json" \
      CLAUDE_GUARD_CA_CERT="$TMP_DIR/cert.pem" \
      CLAUDE_GUARD_IP_RETRIES=1 \
      CLAUDE_GUARD_TLS_RETRIES=3 \
      CLAUDE_GUARD_UI=never \
      "$ROOT_DIR/bin/claude-guard" --precheck-only
  )
}

# $1 = curl 退出码，$2 = 用例名，$3 = unsupported 或 verification-failure
assert_schannel_case() {
  local code="$1" label="$2" expected="$3" bin out status attempts expected_attempts
  bin="$(make_curl "$code")"
  : >"$TMP_DIR/home/curl.log"
  out="$TMP_DIR/out-$code"

  set +e
  run_precheck "$bin" >"$out" 2>&1
  status=$?
  set -e

  if [ "$status" -ne 7 ]; then
    printf '%s: returned %s instead of 7\n' "$label" "$status" >&2
    cat "$out" >&2
    exit 1
  fi

  case "$expected" in
    unsupported)
      if ! grep -q 'Schannel' "$out" || grep -qE '未显示证书验证通过|无法连接或验证' "$out"; then
        printf '%s: must report the deterministic Schannel capability limit\n' "$label" >&2
        cat "$out" >&2
        exit 1
      fi
      if grep -q '次尝试' "$out"; then
        printf '%s: must not claim a retry count it did not spend\n' "$label" >&2
        cat "$out" >&2
        exit 1
      fi
      expected_attempts=1
      ;;
    verification-failure)
      if ! grep -q '无法连接或验证' "$out" || grep -q 'curl 能力限制' "$out"; then
        printf '%s: curl failure must not be classified as deterministic incompatibility\n' "$label" >&2
        cat "$out" >&2
        exit 1
      fi
      if ! grep -q '经过 3 次尝试' "$out"; then
        printf '%s: transient curl failure must retain the configured retry semantics\n' "$label" >&2
        cat "$out" >&2
        exit 1
      fi
      expected_attempts=3
      ;;
    *)
      printf 'unknown expected result: %s\n' "$expected" >&2
      exit 1
      ;;
  esac

  attempts="$(grep -c 'https://api.anthropic.com/ *$' "$TMP_DIR/home/curl.log" || true)"
  if [ "$attempts" -ne "$expected_attempts" ]; then
    printf '%s: expected %s attempts, got %s\n' "$label" "$expected_attempts" "$attempts" >&2
    cat "$TMP_DIR/home/curl.log" >&2
    exit 1
  fi
}

# 1. Schannel 不提供证书元数据，curl 自身成功退出。
assert_schannel_case 0 'schannel without certificate metadata, exit 0' unsupported

# 2. Schannel 握手因证书校验失败以 60 退出。此时空的证书元数据不能证明能力不兼容，
#    必须保留普通连接/验证失败与重试语义。
assert_schannel_case 60 'schannel certificate verification failure' verification-failure

printf 'tls backend platform ok\n'
