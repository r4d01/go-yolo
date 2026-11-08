#!/usr/bin/env bash
# init-firewall.sh DOMAIN... — allow outbound traffic only to DOMAIN... (IPv4), DNS to the
# configured nameservers, and the GitHub ranges from api.github.com/meta. Blocks all IPv6.
# Based on anthropics/claude-code .devcontainer/init-firewall.sh. Exits non-zero on failure.
set -euo pipefail

IPSET=go-yolo-allowed
IPV4_RE='^([0-9]{1,3}\.){3}[0-9]{1,3}$'
CIDR4_RE='^([0-9]{1,3}\.){3}[0-9]{1,3}/[0-9]{1,2}$'

log() { printf 'go-yolo[firewall]: %s\n' "$*" >&2; }
die() { log "error: $*"; exit 1; }

(($#)) || die "no domains given"
for tool in iptables ipset dig curl jq python3 ip; do
  command -v "$tool" >/dev/null 2>&1 || die "$tool not found"
done

mapfile -t nameservers < <(awk '$1 == "nameserver" { print $2 }' /etc/resolv.conf | grep -E "$IPV4_RE" || true)
((${#nameservers[@]})) || die "no IPv4 nameserver in /etc/resolv.conf"

# Flush the filter table only. Docker's NAT rules for the embedded DNS resolver
# (127.0.0.11) live in the nat table and are left untouched.
iptables -P INPUT ACCEPT
iptables -P OUTPUT ACCEPT
iptables -P FORWARD ACCEPT
iptables -F
iptables -X
ipset destroy "$IPSET" 2>/dev/null || true
ipset create "$IPSET" hash:net

# Resolve the allowed domains while the network is still open.
declare -A seen=()
domain_count=0
for domain in "$@"; do
  domain=${domain,,}
  [[ -z ${seen[$domain]:-} ]] || continue
  seen[$domain]=1
  if [[ ! $domain =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$ ]]; then
    log "warning: ignoring invalid domain '$domain'"
    continue
  fi
  mapfile -t ips < <(dig +short +time=3 +tries=2 A "$domain" 2>/dev/null | grep -E "$IPV4_RE" || true)
  if ((${#ips[@]} == 0)); then
    log "warning: $domain did not resolve to any IPv4 address; skipping"
    continue
  fi
  for ip in "${ips[@]}"; do ipset add -exist "$IPSET" "$ip"; done
  domain_count=$((domain_count + 1))
done

# GitHub publishes its IP ranges; add the web/api/git IPv4 ranges, aggregated.
aggregate='
import ipaddress, sys
nets = [ipaddress.ip_network(l.strip(), strict=False) for l in sys.stdin if l.strip()]
for n in ipaddress.collapse_addresses(nets):
    print(n)
'
if meta="$(curl -fsS --max-time 10 https://api.github.com/meta)" \
  && ranges="$(jq -r '(.web + .api + .git)[] | select(contains(":") | not)' <<<"$meta" | python3 -c "$aggregate")"; then
  while IFS= read -r cidr; do
    [[ $cidr =~ $CIDR4_RE ]] || die "invalid CIDR from GitHub meta: $cidr"
    ipset add -exist "$IPSET" "$cidr"
  done <<<"$ranges"
else
  log "warning: could not fetch GitHub IP ranges; relying on DNS for GitHub hosts"
fi

# IPv4 rules.
iptables -A INPUT -i lo -j ACCEPT
iptables -A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
iptables -A OUTPUT -o lo -j ACCEPT
iptables -A OUTPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
for ns in "${nameservers[@]}"; do
  iptables -A OUTPUT -d "$ns" -p udp --dport 53 -j ACCEPT
  iptables -A OUTPUT -d "$ns" -p tcp --dport 53 -j ACCEPT
done
iptables -A OUTPUT -m set --match-set "$IPSET" dst -j ACCEPT
iptables -A OUTPUT -j REJECT --reject-with icmp-admin-prohibited
iptables -P INPUT DROP
iptables -P FORWARD DROP
iptables -P OUTPUT DROP

# IPv6: drop everything except loopback.
if ip6tables -F 2>/dev/null; then
  ip6tables -X
  ip6tables -A INPUT -i lo -j ACCEPT
  ip6tables -A OUTPUT -o lo -j ACCEPT
  ip6tables -A OUTPUT -j REJECT --reject-with icmp6-adm-prohibited
  ip6tables -P INPUT DROP
  ip6tables -P FORWARD DROP
  ip6tables -P OUTPUT DROP
elif [[ -n $(ip -6 route show default 2>/dev/null) || -n $(ip -6 addr show scope global 2>/dev/null) ]]; then
  die "ip6tables is unavailable and the container has IPv6 connectivity"
else
  log "ip6tables unavailable, but the container has no global IPv6 address or route"
fi

# Self-test. The blocked probe must use an address outside the allowlist: example.* sit
# behind CDNs, which an allowed host can share.
probed=0
for probe in example.com example.net example.org; do
  mapfile -t ips < <(dig +short +time=3 +tries=2 A "$probe" 2>/dev/null | grep -E "$IPV4_RE" || true)
  for ip in "${ips[@]}"; do
    if ipset test "$IPSET" "$ip" 2>/dev/null; then continue; fi
    if curl -sS -o /dev/null --max-time 5 --resolve "$probe:443:$ip" "https://$probe" 2>/dev/null; then
      die "self-test failed: https://$probe ($ip) is reachable"
    fi
    probed=1
    break 2
  done
done
((probed)) || log "warning: no probe address outside the allowlist; skipped the blocked-host self-test"
curl -sS -o /dev/null --max-time 5 https://api.github.com \
  || die "self-test failed: https://api.github.com is not reachable"

ip_count="$(ipset list "$IPSET" | grep -cE '^[0-9]')"
log "allowlist active: $domain_count domains, $ip_count IPv4 entries (plus DNS to ${nameservers[*]})"
