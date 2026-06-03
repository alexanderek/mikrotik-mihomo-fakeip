#!/bin/sh
set -eu

repo_root=$(cd -- "$(dirname -- "$0")/.." && pwd)
tmpdir=$(mktemp -d)
trap 'rm -rf "$tmpdir"' EXIT

default_fake_ip_range="198.18.0.0/15"
stub_dir="$tmpdir/bin"
mkdir -p "$stub_dir"

cat > "$stub_dir/lsmod" <<'EOF'
#!/bin/sh
if [ -n "${TEST_LSMOD_OUTPUT:-}" ]; then
  printf '%s\n' "$TEST_LSMOD_OUTPUT"
fi
exit 0
EOF

cat > "$stub_dir/apk" <<'EOF'
#!/bin/sh
case "$1" in
  info) exit 0 ;;
  add|del) exit 0 ;;
esac
exit 0
EOF

cat > "$stub_dir/ip" <<'EOF'
#!/bin/sh
if [ "$1" = "-o" ] && [ "$2" = "link" ] && [ "$3" = "show" ]; then
  echo '2: eth0@if1: <BROADCAST,MULTICAST,UP,LOWER_UP> link/ether 02:42:c0:a8:ff:01 brd ff:ff:ff:ff:ff:ff'
  exit 0
fi
if [ "$1" = "-4" ] && [ "$2" = "addr" ] && [ "$3" = "show" ]; then
  echo '    inet 192.168.255.1/31 scope global eth0'
  exit 0
fi
exit 0
EOF

cat > "$stub_dir/nft" <<'EOF'
#!/bin/sh
if [ "$1" = "flush" ] && [ "$2" = "ruleset" ]; then
  exit 0
fi
if [ "$1" = "-f" ] && [ "$2" = "-" ]; then
  cat > "$TEST_OUTPUT_NFT"
  exit 0
fi
exit 1
EOF

cat > "$stub_dir/mihomo" <<'EOF'
#!/bin/sh
test -f "$MIHOMO_CONFIG_DIR/config.yaml"
cp "$MIHOMO_CONFIG_DIR/config.yaml" "$TEST_OUTPUT_CONFIG"
touch "$TEST_EXEC_MARKER"
EOF

chmod +x "$stub_dir/lsmod" "$stub_dir/apk" "$stub_dir/ip" "$stub_dir/nft" "$stub_dir/mihomo"

assert_contains() {
  file=$1
  pattern=$2
  if ! grep -Fq -- "$pattern" "$file"; then
    echo "Expected to find '$pattern' in $file" >&2
    sed -n '1,220p' "$file" >&2
    exit 1
  fi
}

assert_not_contains() {
  file=$1
  pattern=$2
  if grep -Fq -- "$pattern" "$file"; then
    echo "Did not expect to find '$pattern' in $file" >&2
    sed -n '1,220p' "$file" >&2
    exit 1
  fi
}

run_case() {
  name=$1
  shift
  case_dir="$tmpdir/$name"
  mkdir -p "$case_dir/config"
  (
    # shellcheck disable=SC2030
    PATH="$stub_dir:$PATH"
    MIHOMO_CONFIG_DIR="$case_dir/config"
    MIHOMO_BIN="$stub_dir/mihomo"
    TEST_OUTPUT_CONFIG="$case_dir/config.yaml"
    TEST_OUTPUT_NFT="$case_dir/nft.rules"
    TEST_EXEC_MARKER="$case_dir/executed"
    export PATH MIHOMO_CONFIG_DIR MIHOMO_BIN TEST_OUTPUT_CONFIG TEST_OUTPUT_NFT TEST_EXEC_MARKER
    "$@" sh "$repo_root/entrypoint.sh" >"$case_dir/stdout" 2>"$case_dir/stderr"
  )
  test -f "$case_dir/executed"
  printf '%s\n' "$case_dir/config.yaml"
}

base_config=$(run_case base env \
  FAKE_IP_RANGE="$default_fake_ip_range" \
  FAKE_IP_TTL=60 \
  LOGLEVEL=error)
assert_contains "$base_config" "log-level: error"
assert_contains "$base_config" "fake-ip-range: $default_fake_ip_range"
assert_contains "$base_config" "fake-ip-ttl: 60"
assert_contains "$base_config" "type: tun"
assert_contains "$base_config" "      - eth0"
assert_not_contains "$base_config" "fake-ip-filter:"
assert_not_contains "$base_config" "nameserver-policy:"
assert_not_contains "$base_config" "googlevideo.com"
assert_not_contains "$base_config" "DST-PORT,443)),REJECT"

youtube_tun_config=$(run_case youtube-tun env \
  BLOCK_QUIC=youtube)
assert_contains "$youtube_tun_config" "  - AND,((NETWORK,udp),(DST-PORT,443),(DOMAIN-SUFFIX,googlevideo.com)),REJECT"

tproxy_config=$(run_case tproxy env \
  INBOUND_MODE=tproxy \
  FAKE_IP_RANGE=198.19.0.0/16 \
  BLOCK_QUIC=youtube)
tproxy_nft=$(dirname "$tproxy_config")/nft.rules
assert_contains "$tproxy_config" "type: tproxy"
assert_contains "$tproxy_config" "fake-ip-range: 198.19.0.0/16"
assert_contains "$tproxy_config" "  - AND,((NETWORK,udp),(DST-PORT,443),(DOMAIN-SUFFIX,googlevideo.com)),REJECT"
assert_contains "$tproxy_nft" "ip daddr 198.19.0.0/16 meta l4proto { tcp, udp }"
assert_contains "$tproxy_nft" "198.19.0.0/16"
assert_not_contains "$tproxy_nft" "198.18.0.0/15"

all_quic_config=$(run_case all-quic env \
  INBOUND_MODE=tproxy \
  BLOCK_QUIC=all)
assert_contains "$all_quic_config" "  - AND,((NETWORK,udp),(DST-PORT,443)),REJECT"
assert_not_contains "$all_quic_config" "googlevideo.com"

filter_config=$(run_case filter env \
  FAKE_IP_FILTER="localhost, *.lan,it's.local")
assert_contains "$filter_config" "  fake-ip-filter:"
assert_contains "$filter_config" "    - 'localhost'"
assert_contains "$filter_config" "    - '*.lan'"
assert_contains "$filter_config" "    - 'it''s.local'"

policy_config=$(run_case policy env \
  NAMESERVER_POLICY="*.example.com#tls://9.9.9.9:853, service.example#1.1.1.1")
assert_contains "$policy_config" "  nameserver-policy:"
assert_contains "$policy_config" "    '*.example.com': 'tls://9.9.9.9:853'"
assert_contains "$policy_config" "    'service.example': '1.1.1.1'"

invalid_dir="$tmpdir/invalid-policy"
mkdir -p "$invalid_dir/config"
set +e
(
  # shellcheck disable=SC2031
  PATH="$stub_dir:$PATH"
  MIHOMO_CONFIG_DIR="$invalid_dir/config"
  MIHOMO_BIN="$stub_dir/mihomo"
  TEST_OUTPUT_CONFIG="$invalid_dir/config.yaml"
  TEST_OUTPUT_NFT="$invalid_dir/nft.rules"
  TEST_EXEC_MARKER="$invalid_dir/executed"
  NAMESERVER_POLICY="broken-policy"
  export PATH MIHOMO_CONFIG_DIR MIHOMO_BIN TEST_OUTPUT_CONFIG TEST_OUTPUT_NFT TEST_EXEC_MARKER NAMESERVER_POLICY
  sh "$repo_root/entrypoint.sh" >"$invalid_dir/stdout" 2>"$invalid_dir/stderr"
)
status=$?
set -e
if [ "$status" -eq 0 ]; then
  echo "Invalid NAMESERVER_POLICY unexpectedly succeeded" >&2
  exit 1
fi
if [ -f "$invalid_dir/executed" ]; then
  echo "mihomo stub executed after invalid NAMESERVER_POLICY" >&2
  exit 1
fi
assert_contains "$invalid_dir/stderr" "Invalid NAMESERVER_POLICY entry 'broken-policy': expected domain#dns"

echo "entrypoint smoke tests passed"
