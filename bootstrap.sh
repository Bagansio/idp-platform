#!/bin/sh
# idp-platform bootstrap — installs Tailscale + k3s on any systemd Linux box.
#
# Usage:
#   # VPS / control-plane (has a public IP):
#   PUBLIC_IP=203.0.113.10 \
#     curl -sfL https://raw.githubusercontent.com/Bagansio/idp-platform/main/bootstrap.sh | sh -s -- server
#
#   # Extra worker (e.g. bare-metal at home, behind NAT):
#   TS_AUTHKEY=tskey-xxx K3S_URL=https://<vps-tailscale-ip>:6443 K3S_TOKEN=xxx \
#     curl -sfL https://raw.githubusercontent.com/Bagansio/idp-platform/main/bootstrap.sh | sh -s -- agent
#
# Env vars:
#   SKIP_TAILSCALE (server, optional) set to 1 for a single-node install with no
#               mesh. Private-tier apps then bind to loopback (SSH-tunnel to reach).
#               Add Tailscale + worker nodes later without reinstalling k3s.
#   TS_AUTHKEY  (optional) Tailscale auth key for unattended join; omit to log in interactively.
#   PUBLIC_IP   (server, optional) VPS public IP so LoadBalancer/Ingress serves the internet.
#               If unset, the script auto-detects it; override when auto-detect is wrong.
#   K3S_URL     (agent, required) https://<server-tailscale-ip>:6443
#   K3S_TOKEN   (agent, required) join token from the server (printed at end of server run,
#               or: sudo cat /var/lib/rancher/k3s/server/node-token)
#
# Idempotent: re-running on an already-configured node is a safe no-op.
set -eu

ROLE="${1:-}"
if [ "$ROLE" != "server" ] && [ "$ROLE" != "agent" ]; then
  echo "Usage: bootstrap.sh [server|agent]" >&2
  exit 1
fi

log()  { printf '\n==> %s\n' "$1"; }
warn() { printf '\n!!  %s\n' "$1" >&2; }
die()  { printf '\nXX  %s\n' "$1" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die "Run as root (use sudo)."

# --- 1. Ensure curl exists (needed by upstream installers) -------------------
if ! command -v curl >/dev/null 2>&1; then
  log "Installing curl"
  if   command -v apt-get >/dev/null 2>&1; then apt-get update -y && apt-get install -y curl
  elif command -v dnf     >/dev/null 2>&1; then dnf install -y curl
  elif command -v yum     >/dev/null 2>&1; then yum install -y curl
  elif command -v zypper  >/dev/null 2>&1; then zypper install -y curl
  elif command -v apk     >/dev/null 2>&1; then apk add --no-cache curl
  else die "No known package manager; install curl manually and re-run."
  fi
fi

# --- 2. Tailscale (idempotent; skippable) -----------------------------------
# Set SKIP_TAILSCALE=1 for a single-node install with no mesh (add it later).
# When skipped, cluster traffic uses the default interface and the private tier
# binds to loopback (reach it via `ssh -L 9443:127.0.0.1:9443 <user>@<host>`).
TS_IP=""
if [ "${SKIP_TAILSCALE:-0}" = "1" ]; then
  log "SKIP_TAILSCALE=1 — not installing Tailscale (single-node mode)"
else
  if command -v tailscale >/dev/null 2>&1 && tailscale status >/dev/null 2>&1; then
    log "Tailscale already up, skipping install"
  else
    log "Installing Tailscale"
    curl -fsSL https://tailscale.com/install.sh | sh
    if [ -n "${TS_AUTHKEY:-}" ]; then
      tailscale up --authkey="$TS_AUTHKEY" --ssh
    else
      warn "No TS_AUTHKEY set — bringing Tailscale up interactively; follow the login URL."
      tailscale up --ssh
    fi
  fi
  TS_IP="$(tailscale ip -4 2>/dev/null | head -n1)"
  [ -n "$TS_IP" ] || die "Could not determine Tailscale IPv4 address."
  log "Tailscale IP: $TS_IP"
fi

# --- 3. k3s -----------------------------------------------------------------
if [ "$ROLE" = "server" ]; then
  # Determine the public IP so Ingress/LoadBalancer is reachable from the internet.
  PUB="${PUBLIC_IP:-}"
  if [ -z "$PUB" ]; then
    PUB="$(curl -fsS --max-time 5 https://api.ipify.org 2>/dev/null || true)"
    [ -n "$PUB" ] && log "Auto-detected public IP: $PUB (override with PUBLIC_IP=... if wrong)"
  fi
  [ -n "$PUB" ] || warn "No public IP resolved; public URLs may not bind. Set PUBLIC_IP=... and re-run."

  if systemctl is-active --quiet k3s 2>/dev/null; then
    log "k3s server already running, skipping install"
  else
    log "Installing k3s server"
    # servicelb (klipper) KEPT — it is what binds Traefik to host :80/:443 on a single node.
    # With Tailscale: cluster/flannel traffic stays on the tailnet (--node-ip + --flannel-iface),
    #   and --node-external-ip advertises public services on the public IP.
    # Without Tailscale: only --node-external-ip is set; k3s uses the default interface.
    EXTRA=""
    [ -n "$PUB" ] && EXTRA="$EXTRA --node-external-ip=$PUB"
    if [ -n "$TS_IP" ]; then
      EXTRA="$EXTRA --node-ip=$TS_IP --flannel-iface=tailscale0"
    fi
    curl -sfL https://get.k3s.io | INSTALL_K3S_EXEC="server \
      $EXTRA \
      --write-kubeconfig-mode=644" sh -
  fi

  log "Waiting for node Ready (up to ~60s)"
  i=0
  while [ "$i" -lt 30 ]; do
    if k3s kubectl get nodes 2>/dev/null | grep -q " Ready"; then break; fi
    i=$((i + 1)); sleep 2
  done
  k3s kubectl get nodes || die "Node did not become Ready."

  printf '\n'
  log "Server ready. Join token for agents (KEEP SECRET):"
  cat /var/lib/rancher/k3s/server/node-token
  if [ -n "$TS_IP" ]; then
    printf '\nAgent join command (over Tailscale):\n'
    printf '  TS_AUTHKEY=<key> K3S_URL=https://%s:6443 K3S_TOKEN=<token-above> \\\n' "$TS_IP"
    printf '    curl -sfL https://raw.githubusercontent.com/Bagansio/idp-platform/main/bootstrap.sh | sh -s -- agent\n'
  else
    printf '\n(Single-node mode: no Tailscale. To add worker nodes later, first join this\n'
    printf ' server to a tailnet, then use its 100.x.y.z IP as K3S_URL for agents.)\n'
  fi
else
  # agent
  : "${K3S_URL:?Set K3S_URL=https://<server-tailscale-ip>:6443}"
  : "${K3S_TOKEN:?Set K3S_TOKEN=<token from the server>}"
  if systemctl is-active --quiet k3s-agent 2>/dev/null; then
    log "k3s agent already running, skipping install"
  else
    log "Installing k3s agent, joining $K3S_URL"
    AGENT_EXTRA=""
    [ -n "$TS_IP" ] && AGENT_EXTRA="--node-ip=$TS_IP --flannel-iface=tailscale0"
    curl -sfL https://get.k3s.io | K3S_URL="$K3S_URL" K3S_TOKEN="$K3S_TOKEN" \
      INSTALL_K3S_EXEC="agent $AGENT_EXTRA" sh -
  fi
  log "k3s-agent status:"
  if systemctl is-active --quiet k3s-agent; then
    echo "PASS — agent running. Check 'kubectl get nodes' on the server."
  else
    die "FAIL — k3s-agent is not active. Inspect: journalctl -u k3s-agent -e"
  fi
fi

log "Bootstrap complete for role=$ROLE"
