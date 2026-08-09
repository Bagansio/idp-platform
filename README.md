# idp-platform

A lightweight, GitOps-driven **Internal Developer Platform** you can run on a single VPS
and grow to many machines — without the weight of a full Kubernetes install.

**Stack:** [k3s](https://k3s.io) (tiny CNCF-certified Kubernetes) · [Tailscale](https://tailscale.com)
(zero-config mesh, no open ports) · [Flux CD](https://fluxcd.io) (true GitOps) ·
Traefik (bundled ingress + Let's Encrypt via Cloudflare DNS-01).

> This repo is the **public, reusable platform layer**: the one-command installer, the app
> template, and the docs. Your actual cluster state (real hostnames, secrets, per-app
> manifests) lives in a **separate private repo** that Flux reconciles.

---

## Why this design

| Requirement | How it's met |
|---|---|
| Easy install | One `curl … \| sh` per machine (`bootstrap.sh`), works on any systemd Linux |
| Scalable | Add nodes any time (`… -- agent`); real multi-host Kubernetes, not containers-in-Docker |
| GitOps | Flux reconciles a git repo continuously — drift is auto-corrected, history is auditable |
| Sensible, not overkill | k3s (~0.5–1 GB RAM) instead of kubeadm/etcd HA; Docker demoted to local dev only |
| Secure by default | Node-to-node traffic over Tailscale/WireGuard; secrets SOPS-encrypted in git |

Full rationale (including why **not** kubeadm / Docker Swarm / Nomad / kind / Compose)
is in [`docs/architecture.md`](docs/architecture.md).

---

## Quick start

### 1. Control-plane node (your VPS, has a public IP)

```sh
PUBLIC_IP=<your.vps.public.ip> \
  curl -sfL https://raw.githubusercontent.com/Bagansio/idp-platform/main/bootstrap.sh | sudo sh -s -- server
```

Installs Tailscale + k3s, keeps cluster traffic on the tailnet, advertises public services on
your public IP, and prints an **agent join token** at the end.

### 2. (Optional) extra worker node (e.g. an old PC at home, behind NAT)

```sh
TS_AUTHKEY=<tailscale-auth-key> \
K3S_URL=https://<vps-tailscale-ip>:6443 \
K3S_TOKEN=<token-from-step-1> \
  curl -sfL https://raw.githubusercontent.com/Bagansio/idp-platform/main/bootstrap.sh | sudo sh -s -- agent
```

Joins over Tailscale — no router config, works behind dynamic IP / NAT.

### 3. Bootstrap Flux against your **private** infra repo

```sh
flux bootstrap github \
  --owner=<you> --repository=infra --private --personal \
  --branch=main --path=clusters/vps
```

From here on, **git push is the only deploy action**. See the private repo's README for the
per-app workflow.

---

## Three exposure tiers (all annotation-driven)

| Tier | `router.entrypoints` | auth middleware | Reachable from |
|---|---|---|---|
| Public | `websecure` | – | Internet |
| Public + protected | `websecure` | `security-forward-auth@kubernetescrd` | Internet, login-gated |
| Private | `tailnet` | – | Only your tailnet devices |
| Private + protected | `tailnet` | `security-forward-auth@kubernetescrd` | Tailnet, login-gated |

Switching an app between tiers = changing **one annotation** in its Ingress. See
[`app-template/`](app-template/).

---

## Repo layout

```
bootstrap.sh          One-command installer (server | agent), POSIX sh, idempotent.
app-template/         Copy this to add a new app in the private infra repo.
docs/architecture.md  Full design rationale + alternatives comparison.
```

## License

MIT.
