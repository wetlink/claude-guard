#!/usr/bin/env bash
set -euo pipefail

# curl builds that expose certificate metadata through %{certs} can complete
# the existing issuer/MITM gate without relying on backend-specific verbose text.
# Builds that expose neither %{certs} nor a legacy verbose issuer remain blocked.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

mkdir -p "$TMP_DIR/bin" "$TMP_DIR/home"
cp "$ROOT_DIR/config/official-settings-lifecycle.example.json" "$TMP_DIR/settings.json"
printf 'fixture ca\n' >"$TMP_DIR/cert.pem"
printf '{"command":"/bin/echo","allowed_ips":["203.0.113.10"]}\n' >"$TMP_DIR/allowed.json"

cat >"$TMP_DIR/bin/curl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

args="$*"
printf '%s\n' "$args" >>"$HOME/curl-argv.log"

if printf '%s' "$args" | grep -Eq '(^| )-6( |$)'; then
  exit 7
fi

if printf '%s' "$args" | grep -q '/cdn-cgi/trace'; then
  printf 'fl=1f2\n'
  printf 'h=api.anthropic.com\n'
  printf 'ip=203.0.113.10\n'
  exit 0
fi

host=''
case "$args" in
  *https://api.anthropic.com/*) host='api.anthropic.com' ;;
  *https://platform.claude.com/*) host='platform.claude.com' ;;
esac
[ -n "$host" ] || exit 1

mode="$(cat "$HOME/tls-mode")"
case "$mode" in
  schannel-certs)
    {
      printf '* CONNECT %s:443 HTTP/1.1\n' "$host"
      printf '* CONNECT tunnel established, response 200\n'
      printf '* schannel: disabled automatic use of client certificate\n'
    } >&2
    if printf '%s' "$args" | grep -Fq '%{certs}'; then
      printf 'Subject:CN=%s\n' "$host"
      printf 'Issuer:C=US, O=Example Public CA, CN=Fixture Issuing CA\n'
    fi
    exit 0
    ;;
  schannel-unknown-certs)
    {
      printf '* CONNECT %s:443 HTTP/1.1\n' "$host"
      printf '* CONNECT tunnel established, response 200\n'
      printf '* schannel: disabled automatic use of client certificate\n'
      printf "curl: unknown --write-out variable: 'certs'\n"
    } >&2
    exit 0
    ;;
  legacy-openssl)
    {
      printf '* CONNECT %s:443 HTTP/1.1\n' "$host"
      printf '* CONNECT tunnel established\n'
      printf '*    issuer: C=US; O=Example Public CA; CN=Fixture Issuing CA\n'
    } >&2
    exit 0
    ;;
  curl-fail)
    printf 'curl: (60) fixture certificate verification failure\n' >&2
    exit 60
    ;;
  missing-connect)
    printf 'Issuer:C=US, O=Example Public CA, CN=Fixture Issuing CA\n'
    exit 0
    ;;
  missing-issuer)
    {
      printf '* CONNECT %s:443 HTTP/1.1\n' "$host"
      printf '* CONNECT tunnel established\n'
    } >&2
    exit 0
    ;;
  response-header-issuer)
    {
      printf '* CONNECT %s:443 HTTP/1.1\n' "$host"
      printf '* CONNECT tunnel established\n'
      printf '< issuer: CN=Untrusted Response Header\n'
    } >&2
    exit 0
    ;;
  chain-mitm-leaf)
    # %{certs} 吐的是整条链。叶证书的 issuer 才是 MITM 判据，链尾的公共根不是。
    {
      printf '* CONNECT %s:443 HTTP/1.1\n' "$host"
      printf '* CONNECT tunnel established\n'
    } >&2
    printf 'Subject:CN=%s\n' "$host"
    printf 'Issuer:CN=Charles Proxy CA\n'
    printf 'Subject:CN=Charles Proxy CA\n'
    printf 'Issuer:C=US, O=Example Public CA, CN=Fixture Issuing CA\n'
    printf 'Subject:C=US, O=Example Public CA, CN=Fixture Issuing CA\n'
    printf 'Issuer:C=BE, O=GlobalSign nv-sa, CN=GlobalSign Root CA\n'
    exit 0
    ;;
  verify-fail-with-evidence)
    # 隧道证据齐全、issuer 良性，唯一的失败信号是 curl 的非零退出码——它是
    # 旧版 "SSL certificate verify ok" 字符串检查的唯一接替者，必须单独锁住。
    {
      printf '* CONNECT %s:443 HTTP/1.1\n' "$host"
      printf '* CONNECT tunnel established\n'
    } >&2
    printf 'Issuer:C=US, O=Example Public CA, CN=Fixture Issuing CA\n'
    printf 'curl: (60) SSL certificate problem: unable to get local issuer certificate\n' >&2
    exit 60
    ;;
  certs-connect-injection)
    # stderr 故意没有 CONNECT 证据；证书扩展原始字节在 stdout 中伪造完整隧道行。
    # verbose 与 %{certs} 混流时该文本会污染 CONNECT grep，必须由分流实现拒绝。
    printf 'Subject:CN=%s\n' "$host"
    printf 'Issuer:C=US, O=Example Public CA, CN=Fixture Issuing CA\n'
    printf '1.3.6.1.4.1.11129.2.4.2:fixture raw extension bytes\n'
    printf 'CONNECT tunnel established\n'
    exit 0
    ;;
  mitm-issuer)
    {
      printf '* CONNECT %s:443 HTTP/1.1\n' "$host"
      printf '* CONNECT tunnel established\n'
    } >&2
    printf 'Issuer:CN=mitmproxy Fixture Root\n'
    exit 0
    ;;
esac

exit 1
EOF
chmod +x "$TMP_DIR/bin/curl"

run_precheck() {
  local mode="$1" output_file="$2" tls_retries="${3:-1}"

  printf '%s\n' "$mode" >"$TMP_DIR/home/tls-mode"
  : >"$TMP_DIR/home/curl-argv.log"
  (
    cd "$TMP_DIR"
    HOME="$TMP_DIR/home" \
      USER="guard-test" \
      PATH="$TMP_DIR/bin:$PATH" \
      LANG="en_US.UTF-8" \
      CLAUDE_GUARD_CONFIG="$TMP_DIR/allowed.json" \
      CLAUDE_GUARD_SETTINGS="$TMP_DIR/settings.json" \
      CLAUDE_GUARD_CA_CERT="$TMP_DIR/cert.pem" \
      CLAUDE_GUARD_IP_RETRIES=1 \
      CLAUDE_GUARD_TLS_RETRIES="$tls_retries" \
      CLAUDE_GUARD_LEGACY_PROFILE_MODE=off \
      CLAUDE_GUARD_FINGERPRINT_MODE=off \
      CLAUDE_GUARD_UI=never \
      "$ROOT_DIR/bin/claude-guard" --precheck-only
  ) >"$output_file" 2>&1
}

expect_pass() {
  local mode="$1"
  local output_file="$TMP_DIR/$mode.out"

  if ! run_precheck "$mode" "$output_file"; then
    cat "$output_file" >&2
    printf 'TLS compatibility mode unexpectedly failed: %s\n' "$mode" >&2
    exit 1
  fi
}

expect_exit_7() {
  local mode="$1"
  local output_file="$TMP_DIR/$mode.out"
  local tls_retries="${2:-1}" status

  set +e
  run_precheck "$mode" "$output_file" "$tls_retries"
  status=$?
  set -e
  if [ "$status" -ne 7 ]; then
    cat "$output_file" >&2
    printf 'TLS failure mode returned %s instead of 7: %s\n' "$status" "$mode" >&2
    exit 1
  fi
}

expect_pass schannel-certs
grep -Fq '%{certs}' "$TMP_DIR/home/curl-argv.log" || {
  printf 'Schannel-compatible probe must request curl certificate metadata\n' >&2
  exit 1
}

expect_pass legacy-openssl
expect_exit_7 schannel-unknown-certs 3
grep -Fq '不提供 %{certs} 证书元数据' "$TMP_DIR/schannel-unknown-certs.out" || {
  printf 'unknown %%{certs} must report the deterministic Schannel capability limit\n' >&2
  exit 1
}
unknown_attempts="$(grep -c 'https://api.anthropic.com/ *$' "$TMP_DIR/home/curl-argv.log" || true)"
if [ "$unknown_attempts" -ne 1 ]; then
  printf 'unknown %%{certs} must not retry, got %s attempts\n' "$unknown_attempts" >&2
  exit 1
fi
expect_exit_7 curl-fail
expect_exit_7 missing-connect
expect_exit_7 missing-issuer
expect_exit_7 response-header-issuer
expect_exit_7 mitm-issuer
expect_exit_7 chain-mitm-leaf
expect_exit_7 verify-fail-with-evidence
expect_exit_7 certs-connect-injection

printf 'tls backend compatibility ok\n'
