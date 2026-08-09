# Architecture & rationale

## Goal

A lightweight, GitOps-driven Internal Developer Platform that runs today on a single VPS and can
absorb additional heterogeneous, not-always-on machines later — without the operational weight of
a full multi-master Kubernetes install, and without defaulting to Docker/Compose just because it's
familiar.

## The stack, and why each piece

- **k3s** — a single-binary, CNCF-certified Kubernetes with an embedded datastore, containerd
  runtime, and bundled Traefik ingress. Gives you the full Kubernetes API (so the entire CNCF
  ecosystem "just works") at ~0.5–1 GB RAM, one binary, nothing to babysit at ≤3 nodes.
- **Tailscale** — a WireGuard mesh joining the machines so no inbound ports need opening on either
  box. Cluster/flannel traffic rides the tailnet; a home machine can sit behind NAT/dynamic IP with
  zero router config.
- **Flux CD** — runs *inside* the cluster and continuously reconciles a git repo: `git push` is the
  only deploy action, drift is auto-corrected, history is auditable. This is real GitOps, not "CI
  runs a deploy script."
- **Traefik + Cloudflare DNS-01** — Traefik (bundled with k3s) issues and auto-renews Let's Encrypt
  certificates via the Cloudflare DNS-01 challenge. DNS-01 supports **wildcard certs**, so one
  `*.yourdomain.com` cert covers every app — new apps need zero cert config. No cert-manager needed.
- **SOPS + age** — secrets are encrypted in git (GitOps requires secrets live in git), decrypted
  only in-cluster by Flux.
- **Docker** — demoted to a local dev/build convenience; it is **not** the production runtime.

## Two repos (public platform / private state)

- **`idp-platform` (public)** — the reusable, shareable layer: `bootstrap.sh`, the app template,
  docs. Fetchable with `curl | sh`, no token required.
- **`infra` (private)** — the actual cluster state: real hostnames, Flux config, SOPS-encrypted
  secrets, per-app manifests. Flux bootstraps against this repo with a personal token.

This split keeps the "how to build one" knowledge public while keeping *your* infrastructure private,
and it avoids a chicken-and-egg problem: the public `curl | sh` installer needs no credentials.

## Why not the obvious alternatives

| Option | Verdict | Reasoning |
|---|---|---|
| **kubeadm full k8s (etcd HA)** | Rejected | etcd HA needs 3+ nodes to mean anything; control-plane overhead (~1.5–2 GB RAM) is pure waste at this scale, huge ops surface for zero benefit. |
| **k3s** | **Chosen** | Same Kubernetes API, ~0.5–1 GB RAM, one binary, batteries included (Traefik + local-path storage + Helm controller). Scales by adding `agent` nodes; swap SQLite→etcd only past ~3 nodes. |
| **Docker Swarm** | Rejected | Effectively in maintenance mode; no mature GitOps tool; weak native ingress+cert automation. |
| **Nomad + Consul** | Not chosen | Genuinely lighter and runs non-container jobs, but no mature "apply from git" reconciler like Flux; more assembly for the same outcome. |
| **kind** (Kubernetes IN Docker) | Rejected | Purpose-built for disposable local CI/test clusters: no "survives reboot as a service" story, no real production networking, its multi-node model is containers-on-one-host, not multiple physical machines. |
| **PaaS-in-a-box (Coolify / CapRover / Dokploy)** | Not chosen | Easiest for a single solo VPS, but weaker multi-node story, and their "GitOps" is usually a redeploy webhook, not desired-state reconciliation. Documented fallback if k3s+Flux ever feels like overkill. |
| **Compose + git-pull cron** | Rejected as the platform | No reconciliation, drift detection, rollback, or clean multi-node model. Kept only for local dev. |

**Bottom line:** k3s gives a real Kubernetes API (portable skills, huge ecosystem, trivially
scalable) at Raspberry-Pi resource cost; Flux gives *actual* GitOps; Docker stays where it makes
sense (local builds).

## Target topology (after a second node joins)

```
  Git: infra repo (private)  ──poll──▶  Flux (in-cluster)  ──reconciles──▶  cluster
                                                                              │
        VPS  ── k3s server ──┐                                               │
         (public IP,         ├── Tailscale mesh (WireGuard, no open ports) ──┤
          control-plane)     │                                               │
        Home PC ── k3s agent ┘  (behind NAT, worker only)                    ▼
                                                        Traefik ingress → users (public tier)
                                                                        → tailnet (private tier)
```

- **Single control plane on the VPS** (stable public IP); extra machines join as **agents** (workers)
  and never need to be internet-reachable.
- **Storage** stays on k3s's built-in local-path-provisioner until a workload genuinely needs
  cross-node replication (add Longhorn later, per-app, only if needed).

## Three exposure tiers

Controlled entirely by annotations on each app's Ingress — no per-app pattern differences:

| Tier | `router.entrypoints` | auth middleware | Reachable from |
|---|---|---|---|
| Public | `websecure` | – | Internet |
| Public + protected | `websecure` | `security-forward-auth@kubernetescrd` | Internet, login-gated |
| Private | `tailnet` | – | Only tailnet devices |
| Private + protected | `tailnet` | `security-forward-auth@kubernetescrd` | Tailnet, login-gated |

- **Public** apps bind Traefik's `websecure` entrypoint (all interfaces) and get the wildcard TLS cert.
- **Private** apps bind a `tailnet` entrypoint bound only to the node's Tailscale IP — unreachable
  from the internet by network topology, not just by a login wall. (Private-tier TLS uses
  `tailscale cert` for `*.ts.net` names or self-signed, since Let's Encrypt won't issue for tailnet
  names.)
- **Auth** (any tier) is a `forwardAuth` middleware backed by Authelia (SSO across all apps) or a
  simple `basicAuth` middleware.

## Risks / tradeoffs

- **Single control-plane node is a SPOF for the API/scheduler** — but *running* workloads keep
  serving even if the control plane is briefly down. Acceptable at this scale; documented rather
  than solved with a third node you don't have.
- **k3s SQLite datastore** is fine for ≤3 nodes; migrating to embedded etcd past that is supported
  but non-trivial.
- **Tailscale is a third-party mesh control plane** (generous free tier). Alternative for zero third
  parties: hand-configured WireGuard — more setup, no account.
