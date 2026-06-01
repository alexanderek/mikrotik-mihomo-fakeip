#!/bin/sh

if ! lsmod | grep nf_tables >/dev/null 2>&1; then
  if ! apk info -e iptables iptables-legacy >/dev/null 2>&1; then
    echo "Install iptables"
    apk add --no-cache iptables iptables-legacy >/dev/null 2>&1 || exit 1
    rm -f /usr/sbin/iptables /usr/sbin/iptables-save /usr/sbin/iptables-restore || exit 1
    ln -s /usr/sbin/iptables-legacy /usr/sbin/iptables || exit 1
    ln -s /usr/sbin/iptables-legacy-save /usr/sbin/iptables-save || exit 1
    ln -s /usr/sbin/iptables-legacy-restore /usr/sbin/iptables-restore || exit 1
  fi
else
  if ! apk info -e nftables >/dev/null 2>&1; then
    echo "Install nftables"
    apk add --no-cache nftables >/dev/null 2>&1 || exit 1
  fi
  if apk info -e iptables iptables-legacy >/dev/null 2>&1; then
    echo "Delete iptables"
    apk del iptables iptables-legacy >/dev/null 2>&1 || exit 1
  fi
fi

FAKE_IP_RANGE="${FAKE_IP_RANGE:-198.18.0.0/15}"
FAKE_IP_FILTER="${FAKE_IP_FILTER:-}"
FAKE_IP_TTL="${FAKE_IP_TTL:-1}"

trim() {
  printf '%s' "$1" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//'
}

yaml_quote() {
  printf '%s' "$1" | sed "s/'/''/g"
}

generate_fake_ip_filter() {
  [ -z "${FAKE_IP_FILTER:-}" ] && return 0

  OLDIFS=$IFS
  case $- in
    *f*) had_noglob=1 ;;
    *) had_noglob=0; set -f ;;
  esac

  IFS=','
  printed=0
  for raw in $FAKE_IP_FILTER; do
    item=$(trim "$raw")
    [ -z "$item" ] && continue
    if [ "$printed" -eq 0 ]; then
      echo "  fake-ip-filter:"
      printed=1
    fi
    printf "    - '%s'\n" "$(yaml_quote "$item")"
  done

  IFS=$OLDIFS
  [ "$had_noglob" -eq 0 ] && set +f
  return 0
}

#   NAMESERVER_POLICY="domain1#dns1,domain2#dns2"
generate_nameserver_policy() {
  [ -z "${NAMESERVER_POLICY:-}" ] && return 0

  OLDIFS=$IFS
  case $- in
    *f*) had_noglob=1 ;;
    *) had_noglob=0; set -f ;;
  esac

  IFS=','
  printed=0
  for raw in $NAMESERVER_POLICY; do
    item=$(trim "$raw")
    [ -z "$item" ] && continue
    case "$item" in
      *#*) ;;
      *)
        echo "Invalid NAMESERVER_POLICY entry '$item': expected domain#dns" >&2
        IFS=$OLDIFS
        [ "$had_noglob" -eq 0 ] && set +f
        return 1
        ;;
    esac
    domain=${item%%#*}
    dns=${item#*#}
    if [ -z "$domain" ] || [ -z "$dns" ]; then
      echo "Invalid NAMESERVER_POLICY entry '$item': domain and dns must be non-empty" >&2
      IFS=$OLDIFS
      [ "$had_noglob" -eq 0 ] && set +f
      return 1
    fi
    case "$dns" in
      *#*)
        echo "Invalid NAMESERVER_POLICY entry '$item': expected exactly one #" >&2
        IFS=$OLDIFS
        [ "$had_noglob" -eq 0 ] && set +f
        return 1
        ;;
    esac
    if [ "$printed" -eq 0 ]; then
      echo "  nameserver-policy:"
      printed=1
    fi
    printf "    '%s': '%s'\n" "$(yaml_quote "$domain")" "$(yaml_quote "$dns")"
  done

  IFS=$OLDIFS
  [ "$had_noglob" -eq 0 ] && set +f
  return 0
}

first_iface() {
  ip -o link show | awk -F': ' '/link\/ether/ {print $2}' | cut -d'@' -f1 | head -n1
}

require_first_iface() {
  iface=$(first_iface)
  if [ -z "$iface" ]; then
    echo "No ethernet interface found" >&2
    return 1
  fi
  printf '%s\n' "$iface"
}

config_file_mihomo_tproxy() {
cat > /root/.config/mihomo/config.yaml << EOF
log-level: ${LOGLEVEL:-error}
ipv6: false
dns:
  enable: true
  cache-algorithm: arc
  prefer-h3: false
  use-system-hosts: false
  respect-rules: false
  listen: 0.0.0.0:53
  ipv6: false
  default-nameserver:
    - 8.8.8.8
    - 9.9.9.9
    - 1.1.1.1
  enhanced-mode: fake-ip
  fake-ip-range: ${FAKE_IP_RANGE}
  fake-ip-ttl: ${FAKE_IP_TTL}
EOF
generate_fake_ip_filter >> /root/.config/mihomo/config.yaml || return 1
generate_nameserver_policy >> /root/.config/mihomo/config.yaml || return 1
cat >> /root/.config/mihomo/config.yaml <<EOF
  nameserver:
    - https://dns.google/dns-query
    - https://cloudflare-dns.com/dns-query
    - https://dns.quad9.net/dns-query
hosts:
  dns.google: [8.8.8.8, 8.8.4.4]
  dns.quad9.net: [9.9.9.9, 149.112.112.112]
  cloudflare-dns.com: [104.16.248.249, 104.16.249.249]

listeners:
  - name: tproxy-in
    type: tproxy
    port: 12345
    listen: 0.0.0.0
    udp: true

rules:
  - MATCH,DIRECT

EOF
}
config_file_mihomo_tun() {
iface=$(require_first_iface) || return 1
cat > /root/.config/mihomo/config.yaml << EOF
log-level: ${LOGLEVEL:-error}
ipv6: false
dns:
  enable: true
  cache-algorithm: arc
  prefer-h3: false
  use-system-hosts: false
  respect-rules: false
  listen: 0.0.0.0:53
  ipv6: false
  default-nameserver:
    - 8.8.8.8
    - 9.9.9.9
    - 1.1.1.1
  enhanced-mode: fake-ip
  fake-ip-range: ${FAKE_IP_RANGE}
  fake-ip-ttl: ${FAKE_IP_TTL}
EOF
generate_fake_ip_filter >> /root/.config/mihomo/config.yaml || return 1
generate_nameserver_policy >> /root/.config/mihomo/config.yaml || return 1
cat >> /root/.config/mihomo/config.yaml <<EOF
  nameserver:
    - https://dns.google/dns-query
    - https://cloudflare-dns.com/dns-query
    - https://dns.quad9.net/dns-query
hosts:
  dns.google: [8.8.8.8, 8.8.4.4]
  dns.quad9.net: [9.9.9.9, 149.112.112.112]
  cloudflare-dns.com: [104.16.248.249, 104.16.249.249]

listeners:
  - name: tun-in
    type: tun
    stack: system
    dns-hijack:
    - 0.0.0.0:53
    auto-detect-interface: false
    include-interface:
      - ${iface}
    auto-route: true
    strict-route: true
    auto-redirect: true
    inet4-address:
    - 198.19.0.1/30
    udp-timeout: 30
    mtu: 1500

rules:
  - AND,((NETWORK,udp),(DST-PORT,443),(DOMAIN-SUFFIX,googlevideo.com)),REJECT
  - MATCH,DIRECT
EOF
}

nft_rules () {
iface=$(require_first_iface) || return 1
iface_ip=$(ip -4 addr show "$iface" | awk '/inet / {print $2}' | cut -d/ -f1 | head -n1)
if [ -z "$iface_ip" ]; then
  echo "No IPv4 address found on interface $iface" >&2
  return 1
fi

nft flush ruleset || return 1
nft -f - <<EOF || return 1
table inet mihomo_tproxy {
    chain prerouting {
        type filter hook prerouting priority filter; policy accept;
        ip daddr ${FAKE_IP_RANGE} meta l4proto { tcp, udp } iifname "${iface}" meta mark set 0x00000001 tproxy ip to 127.0.0.1:12345 accept
        ip daddr { ${iface_ip}, 0.0.0.0/8, 127.0.0.0/8, 224.0.0.0/4, 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16, 100.64.0.0/10, 169.254.0.0/16, 192.0.0.0/24, 192.0.2.0/24, 198.51.100.0/24, 203.0.113.0/24, 192.88.99.0/24, 198.18.0.0/15, 224.0.0.0/3 } return
        meta l4proto { tcp, udp } iifname "${iface}" meta mark set 0x00000001 tproxy ip to 127.0.0.1:12345 accept
    }

    chain divert {
        type filter hook prerouting priority mangle; policy accept;
        meta l4proto tcp socket transparent 1 meta mark set 0x00000001 accept
    }
}
EOF
ip rule show | grep -q 'fwmark 0x00000001 lookup 100' || ip rule add fwmark 1 table 100 || return 1
ip route replace local 0.0.0.0/0 dev lo table 100 || return 1
}

run() {
mkdir -p /root/.config/mihomo
if lsmod | grep -q '^nft_tproxy'; then
   echo "nft_tproxy module loaded, use inbound TPROXY"
   nft_rules || return 1
   config_file_mihomo_tproxy || return 1
else
   echo "nft_tproxy not loaded, use inbound TUN with TCP redirect"
   config_file_mihomo_tun || return 1
fi
exec ./mihomo
}

run || exit 1
