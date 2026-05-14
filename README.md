# home-ops-template

A opinionated, batteries-included Kubernetes home-lab template built on [Talos Linux](https://www.talos.dev/) and [Flux CD](https://fluxcd.io/). Inspired by [onedr0p/cluster-template](https://github.com/onedr0p/cluster-template).

## What's included

| Category | Apps |
|---|---|
| **Core** | Talos Linux, Flux CD, Cilium, CoreDNS, metrics-server, reloader, spegel, VPA |
| **Networking** | Envoy Gateway, k8s-gateway, Cloudflare DNS + Tunnel, Pi-hole, wg-easy |
| **Storage** | NFS CSI, SeaweedFS S3, Longhorn, Volsync, s3manager |
| **Databases** | CloudNative-PG, Dragonfly |
| **Observability** | Prometheus, Grafana, Loki, Fluent-bit, Gatus, Kromgo, smartctl-exporter, Goldilocks |
| **Media** | Jellyfin, Immich, Kavita, Radarr, Sonarr, Bazarr, Prowlarr, Transmission, Autobrr, Flaresolverr, Overseerr, Recyclarr |
| **Cloud** | Nextcloud |
| **Dev** | Forgejo + Actions runners, Woodpecker CI, Homepage |
| **Home Automation** | Home Assistant |
| **System** | cert-manager, snapshot-controller, system-upgrade (tuppr) |
| **Utility** | echo |

## Prerequisites

### Required tools

```sh
age-keygen  # secret encryption
cue         # schema validation
flux        # GitOps toolkit
helmfile    # helm chart orchestration
kubeconform # kubernetes manifest validation
makejinja   # template rendering (pip install makejinja)
sops        # secret management
ssh-keygen  # deploy key generation
talhelper   # Talos config helper
talosctl    # Talos CLI
task        # task runner (taskfile.dev)
```

### Required accounts / services

- **Cloudflare** account with a domain managed in Cloudflare DNS
- **Cloudflare Tunnel** — create a tunnel and download `cloudflare-tunnel.json` to the repo root
- **GitHub** repository for this cluster (used by Flux)
- A NAS or NFS server for persistent storage

### Cloudflare API token

Create a token with:
- `Zone:DNS:Edit`
- `Account:Cloudflare Tunnel:Read`

## Quick start

### 1. Initialize

```sh
task init
```

This copies `cluster.sample.yaml` → `cluster.yaml` and `nodes.sample.yaml` → `nodes.yaml`, then generates:
- `age.key` — SOPS encryption key
- `github-deploy.key` — Flux read-only deploy key
- `github-push-token.txt` — Flux image update push token

### 2. Configure

Edit `cluster.yaml` with your network details, Cloudflare credentials, NFS paths, and app passwords. Edit `nodes.yaml` with your node information (IP, disk, MAC, schematic ID from [factory.talos.dev](https://factory.talos.dev)).

Add your Cloudflare tunnel JSON to the repo root:

```sh
# Download from Cloudflare dashboard or cloudflared CLI
# and place as: cloudflare-tunnel.json
```

Then render and encrypt:

```sh
task configure
```

This validates schemas, renders all Jinja2 templates, encrypts SOPS secrets, and validates the resulting Kubernetes and Talos configs.

### 3. Push to GitHub

Add the deploy key from `github-deploy.key.pub` to your GitHub repository (Settings → Deploy keys, read-only).

Commit and push:

```sh
git add -A && git commit -m "feat: initial cluster configuration"
git push
```

### 4. Bootstrap Talos

```sh
task bootstrap:talos
```

This generates Talos secrets, renders node configs, applies them, bootstraps etcd, and fetches `kubeconfig`.

### 5. Bootstrap apps

```sh
task bootstrap:apps
```

Installs Flux and bootstraps all cluster applications via Helmfile.

### 6. Bootstrap SeaweedFS S3

```sh
task storage:bootstrap-seaweedfs
```

Creates S3 buckets, generates access keys, and writes the credentials back into `cluster.yaml` automatically. Re-run `task configure` and push after this step to propagate the credentials.

## Day-2 operations

| Command | Description |
|---|---|
| `task reconcile` | Force Flux to pull latest changes |
| `task storage:restore-pvc -- <ns> <pvc> <size>` | Restore a PVC from Volsync backup |
| `task debug` | Dump common cluster resources |
| `task template:tidy` | Archive template scaffolding after cluster is live |

## Repository layout

```
├── cluster.yaml          # Your cluster configuration (gitignored after configure)
├── nodes.yaml            # Your node definitions (gitignored after configure)
├── templates/            # Jinja2 templates rendered by `task configure`
│   └── config/
│       ├── bootstrap/    # Helmfile bootstrap charts
│       ├── kubernetes/   # Flux app manifests
│       └── talos/        # Talos machine configs
├── .taskfiles/           # Task runner includes
│   ├── bootstrap/        # bootstrap:talos, bootstrap:apps
│   ├── storage/          # storage:bootstrap-seaweedfs, storage:restore-pvc
│   ├── talos/            # talos utilities
│   └── template/         # init, configure, tidy tasks
└── scripts/              # Shell scripts called by tasks
```
