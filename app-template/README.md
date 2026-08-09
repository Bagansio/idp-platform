# app-template

Copy this folder into your **private `infra` repo** to add a new app, then push — Flux deploys it.

## Steps

```sh
# in your infra repo:
cp -r /path/to/idp-platform/app-template apps/myapp
cd apps/myapp
# 1. edit deployment.yaml -> image + containerPort
# 2. edit service.yaml    -> port / targetPort
# 3. edit ingress.yaml    -> host, exposure tier, optional auth
# 4. reference it from clusters/vps/apps/kustomization.yaml
git add . && git commit -m "feat: add myapp" && git push
```

Within ~1 minute Flux reconciles it and Traefik serves it.

## Choosing exposure (edit `ingress.yaml` annotations)

| Want | entrypoints | middlewares |
|---|---|---|
| Public, open | `websecure` | (none) |
| Public, login-gated | `websecure` | `security-forward-auth@kubernetescrd` |
| Private (tailnet only) | `tailnet` | (none) |
| Private, login-gated | `tailnet` | `security-forward-auth@kubernetescrd` |

TLS for public apps is automatic — a cluster-wide `*.yourdomain.com` wildcard cert is issued by
Traefik's Cloudflare DNS-01 resolver, so there's nothing to configure per app.
