#!/bin/sh
# origin-firewall.sh — lock inbound 80/443 to Cloudflare's IP ranges only.
#
# WHY: once your domain is proxied through Cloudflare (orange cloud), all real
# traffic arrives FROM Cloudflare's edge. Attackers who know your raw origin IP
# can still bypass Cloudflare by hitting the IP directly — UNLESS the origin
# drops web traffic that isn't from Cloudflare. This script does that.
#
# SAFETY: applies an nftables ruleset, then arms a dead-man's-switch. If you do
# not run `touch /run/fw-confirm` within CONFIRM_SECS, it auto-reverts — so a
# mistake can NEVER lock you out permanently. SSH (22) is always left open.
#
# Usage (on the VPS, as root):
#   sh origin-firewall.sh apply     # apply + arm auto-rollback
#   touch /run/fw-confirm           # <-- run within 5 min if the site still works
#   sh origin-firewall.sh revert    # manually remove the ruleset
#
# PREREQUISITE: enable the Cloudflare proxy (orange cloud) FIRST, or real users
# get blocked. See the runbook printed by `sh origin-firewall.sh check`.
set -eu

CONFIRM_SECS="${CONFIRM_SECS:-300}"
TABLE="cf_origin"
ACTION="${1:-check}"

log(){ printf '\n==> %s\n' "$1"; }

fetch_cf(){
  # Cloudflare publishes its ranges at these stable URLs.
  curl -fsS https://www.cloudflare.com/ips-v4 2>/dev/null
  echo
  curl -fsS https://www.cloudflare.com/ips-v6 2>/dev/null
  echo
}

apply(){
  command -v nft >/dev/null 2>&1 || { echo "installing nftables"; apt-get update -qq && apt-get install -y -qq nftables; }
  V4=$(curl -fsS https://www.cloudflare.com/ips-v4); V6=$(curl -fsS https://www.cloudflare.com/ips-v6)
  [ -n "$V4" ] || { echo "could not fetch Cloudflare IPv4 ranges; aborting"; exit 1; }

  # comma-join for nft set element syntax
  SET4=$(printf '%s' "$V4" | paste -sd, -)
  SET6=$(printf '%s' "$V6" | paste -sd, -)

  log "Applying Cloudflare-only firewall for tcp/80 + tcp/443 (SSH stays open)"
  nft delete table inet "$TABLE" 2>/dev/null || true
  nft -f - <<EOF
table inet $TABLE {
  set cf4 { type ipv4_addr; flags interval; elements = { $SET4 } }
  set cf6 { type ipv6_addr; flags interval; elements = { $SET6 } }
  chain input {
    type filter hook input priority -10; policy accept;
    # allow established/related + loopback
    ct state established,related accept
    iif "lo" accept
    # SSH always allowed (never lock out)
    tcp dport 22 accept
    # web only from Cloudflare
    tcp dport { 80, 443 } ip  saddr @cf4 accept
    tcp dport { 80, 443 } ip6 saddr @cf6 accept
    # drop any other web traffic (direct-to-IP bypass attempts)
    tcp dport { 80, 443 } drop
  }
}
EOF
  log "Ruleset applied. ARMING auto-rollback in ${CONFIRM_SECS}s."
  echo "   >>> If the site STILL WORKS via https://<yourdomain>, run:  touch /run/fw-confirm"
  echo "   >>> If you do nothing, the firewall auto-reverts (fail-safe)."
  rm -f /run/fw-confirm
  # background watchdog
  ( sleep "$CONFIRM_SECS"
    if [ ! -f /run/fw-confirm ]; then
      nft delete table inet "$TABLE" 2>/dev/null || true
      logger -t origin-firewall "auto-reverted: no confirmation within ${CONFIRM_SECS}s"
    else
      logger -t origin-firewall "confirmed: ruleset kept"
      # persist so it survives reboot
      mkdir -p /etc/nftables.d 2>/dev/null || true
      nft list table inet "$TABLE" > /etc/nftables-cf-origin.nft 2>/dev/null || true
    fi
  ) >/dev/null 2>&1 &
  echo "watchdog PID $!"
}

revert(){ log "Removing Cloudflare-only firewall"; nft delete table inet "$TABLE" 2>/dev/null || true; rm -f /run/fw-confirm; echo "reverted"; }

check(){
  echo "Cloudflare IPv4 ranges currently published:"; fetch_cf | sed 's/^/  /'
  echo
  echo "RUNBOOK:"
  echo "  1. Enable the orange-cloud proxy on your A records in the Cloudflare dashboard."
  echo "  2. Set SSL/TLS mode to 'Full (strict)' (your origin has a valid LE cert)."
  echo "  3. Verify the site loads through Cloudflare."
  echo "  4. sh origin-firewall.sh apply    (then touch /run/fw-confirm within ${CONFIRM_SECS}s)"
}

case "$ACTION" in
  apply) apply ;;
  revert) revert ;;
  check) check ;;
  *) echo "Usage: origin-firewall.sh [apply|revert|check]"; exit 1 ;;
esac
