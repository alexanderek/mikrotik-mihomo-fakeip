# mikrotik-mihomo-fakeip
> Maintained fork of an archived upstream project.
> Original repository is archived; this fork continues maintenance and documentation updates.

This repository provides a Mihomo build with an integrated configuration, designed for deployment on MikroTik RouterOS via containerization, utilizing DNS static forwarding and the native RouterOS tunneling features.

## Environment variables

The container currently supports these environment variables:

| Variable | What it does | Default | Example |
|---|---|---|---|
| `FAKE_IP_RANGE` | Fake-IP pool used by `dns.fake-ip-range` | `198.18.0.0/15` | `198.18.0.0/15` |
| `FAKE_IP_TTL` | Fake-IP TTL used by `dns.fake-ip-ttl` | `1` | `60` |
| `LOGLEVEL` | Mihomo `log-level` in generated config | `error` | `warning` |
| `FAKE_IP_FILTER` | Optional CSV list converted to a YAML-quoted `dns.fake-ip-filter` list | empty | `localhost,*.lan,*.local` |
| `NAMESERVER_POLICY` | Optional CSV `domain#dns` list converted to `dns.nameserver-policy` | empty | `*.example.com#tls://9.9.9.9:853` |
| `BLOCK_QUIC` | Optional UDP/443 reject policy in Mihomo rules | `off` | `youtube` |
| `INBOUND_MODE` | Inbound mode selector: `auto`, `tun`, or `tproxy` | `auto` | `tproxy` |

`198.18.0.0/15` is the reserved RFC2544 benchmarking range and is Mihomo's
default fake-ip pool. Avoid RFC1918 ranges such as `10.0.0.0/8` for fake IPs:
they can overlap real LAN/VPN addresses.

Current generated DNS defaults (fixed in `entrypoint.sh`, no env override):
- `dns.listen: 0.0.0.0:53`
- `dns.enhanced-mode: fake-ip`
- `dns.default-nameserver: [8.8.8.8, 9.9.9.9, 1.1.1.1]`
- `ipv6: false`

## DNS listener contract

The container listens for DNS on `0.0.0.0:53`, which means RouterOS reaches it
on the container interface IP. In `enhanced-mode: fake-ip`, matching downstream
DNS forwarder queries receive addresses from `FAKE_IP_RANGE`.

Downstream RouterOS DNS forwarders and health checks should target the container
interface IP and should expect fake-ip answers inside `FAKE_IP_RANGE`.

WG egress-failover integration puts this container into a single egress routing
table and is documented separately in the `wg-failover` repository. The
standalone `fakeip` routing table below is an illustration for independent
deployments, not the failover integration contract.

## NAMESERVER_POLICY (dns.nameserver-policy)

Format:

```bash
NAMESERVER_POLICY="domain1#dns1,domain2#dns2"
```

- Elements are separated by commas.
- Inside each element, exactly one `#` separates `domain` and upstream `dns`.
- Empty `domain` or `dns` values are rejected during container startup.
- Upstream examples: `1.1.1.1`, `tls://9.9.9.9:853`.

Examples:

```bash
NAMESERVER_POLICY="*.example.com#tls://9.9.9.9:853"
NAMESERVER_POLICY="service.example#tls://9.9.9.9:853,updates.example.net#tls://9.9.9.9:853"
NAMESERVER_POLICY="video.example#1.1.1.1,*.example.org#1.1.1.1"
```

> **Note**: Invalid `NAMESERVER_POLICY` entries stop startup instead of generating a broken configuration.

## BLOCK_QUIC

`BLOCK_QUIC` controls optional UDP/443 reject rules in the generated Mihomo
config. It is disabled by default and is unrelated to failover decisions.

- `off`: do not reject QUIC.
- `youtube`: reject UDP/443 only for `DOMAIN-SUFFIX,googlevideo.com`. This can
  force TCP fallback for YouTube/video traffic through a tunnel.
- `all`: reject all UDP/443 traffic.

The same policy is applied in both `tun` and `tproxy` inbound modes.

## INBOUND_MODE

`INBOUND_MODE` controls how the container chooses the Mihomo inbound mode:

- `auto`: use the legacy runtime heuristic and select `tproxy` when `nft_tproxy`
  is visible from inside the container; otherwise select `tun`.
- `tun`: force TUN inbound.
- `tproxy`: force nftables TPROXY inbound.

## Example Usage

This example demonstrates how to integrate the `mikrotik-mihomo-fakeip` container with MikroTik RouterOS to enable fake DNS forwarding. Fake IPs are issued for specific domains, routed back to the container, and outgoing traffic can be directed to any destination (including standard RouterOS tunnels).

### 1. Create a container interface

```bash
/interface/veth/add name=fakeip address=192.168.255.1/31 gateway=192.168.255.0
```

### 2. Assign the interface address to MikroTik

```bash
/ip/address/add address=192.168.255.0/31 interface=fakeip
```

### 3. Create DNS forwarders with the container’s IP address

```bash
/ip/dns/forwarders/add name=fakeip dns-servers=192.168.255.1 verify-doh-cert=no
```

### 4. Add environment variables

Set required variables, then optionally add `FAKE_IP_FILTER` and `NAMESERVER_POLICY`:

```bash
/container/envs
add key=FAKE_IP_RANGE list=fakeip value=198.18.0.0/15
add key=LOGLEVEL list=fakeip value=error
add key=FAKE_IP_TTL list=fakeip value=1
add key=BLOCK_QUIC list=fakeip value=off
add key=FAKE_IP_FILTER list=fakeip value="localhost,*.lan,*.local"
add key=NAMESERVER_POLICY list=fakeip value="*.example.com#tls://9.9.9.9:853"
```

### 5. Pull and run the container

```bash
/container/add remote-image="ghcr.io/alexanderek/mikrotik-mihomo-fakeip:latest" envlists=fakeip interface=fakeip root-dir=Containers/fakeip start-on-boot=yes
```

> **Note**: Depending on RouterOS version, CLI may show `envlists` or `envlist`; use tab-completion.
> **Note**: Published tags are `latest` and versioned `vX.Y.Z` multi-arch images. The amd64 image is built with `GOAMD64=v3` for modern x86_64 systems, `linux/arm64` targets RB5009, and `linux/arm/v7` targets RB4011.

### 6. Add a route for fake IPs to the container’s gateway

```bash
/ip/route/add dst-address=198.18.0.0/15 gateway=192.168.255.1
```

### 7. Create a DNS address list to exclude from routing

```bash
/ip/firewall/address-list
add address=1.1.1.1 list=DNS
add address=9.9.9.9 list=DNS
add address=149.112.112.112 list=DNS
add address=104.16.248.249 list=DNS
add address=104.16.249.249 list=DNS
add address=8.8.8.8 list=DNS
add address=8.8.4.4 list=DNS
```

> **Note**: This list prevents routing loops by excluding upstream DNS servers from further routing.

### 8. Add a routing table for container traffic

```bash
/routing/table/add name=fakeip fib
```

### 9. Example mangle rules

```bash
/ip/firewall/mangle
add action=mark-connection chain=prerouting connection-mark=no-mark dst-address-list=!DNS dst-address-type=!local new-connection-mark=fakeip src-address=192.168.255.1
add action=mark-routing chain=prerouting connection-mark=fakeip in-interface=fakeip new-routing-mark=fakeip passthrough=no
```

### 10. Add domains for fake IP resolution

```bash
/ip/dns/static/add type=FWD forward-to=fakeip match-subdomain=yes name=video.example
/ip/dns/static/add type=FWD forward-to=fakeip match-subdomain=yes name=service.example
/ip/dns/static/add type=FWD forward-to=fakeip match-subdomain=yes name=updates.example.net
```

> **Note**: Repeat this command for additional domains that should resolve to fake IPs.

### 11. Summary and final configuration

This configuration issues fake IPs for specified domains via `FWD` rules, routes them back to the container, and allows outgoing traffic to be directed anywhere, including standard RouterOS tunnels.

```bash
/ip/route/add dst-address=0.0.0.0/0 gateway=XXX.XXX.XXX.XXX routing-table=fakeip
```

> **Note**: Replace XXX.XXX.XXX.XXX with your actual gateway to complete the routing setup.

## Minimal test plan / Verification

1. Start the container and confirm it is running:

```bash
/container/print where name~"mihomo"
```

2. Confirm config exists inside the container:

```bash
/container/shell <container-id-or-name>
cat /root/.config/mihomo/config.yaml
```

3. If `NAMESERVER_POLICY` is set, confirm `nameserver-policy:` is present in `config.yaml`.

4. From a client device in your LAN, query the router DNS and verify domains matched by your `type=FWD` rules return fake IPs (this is expected behavior in fake-ip mode). Replace `<ROUTER_DNS_IP>` with your router's DNS IP (LAN IP).

```bash
# Client device commands:
# Windows:
nslookup service.example <ROUTER_DNS_IP>
# Linux/macOS:
dig @<ROUTER_DNS_IP> service.example

# RouterOS DNS cache check:
/ip dns cache print where name~"service.example"
```

5. For a live HTTP end-to-end check, prefer `neverssl.com`. It is intentionally plain HTTP and avoids confusing failures from HTTPS redirects or CDN behavior.

```bash
# RouterOS DNS direct-to-container check:
:put [:resolve neverssl.com server=<CONTAINER_IP>]

# RouterOS fake-ip traffic check:
# Replace <FAKE_IP> with the address returned by the resolve command.
/tool/fetch url="http://<FAKE_IP>/" http-header-field="Host: neverssl.com" output=none duration=15s
```

The returned fake IP should be inside `FAKE_IP_RANGE`, and Mihomo logs should show a TCP flow to `neverssl.com:80`.
