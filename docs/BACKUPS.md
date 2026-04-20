# Backup System

## Architecture

The cluster uses three complementary backup systems, all targeting **Garage S3** on your NAS:

```
┌─────────────────────────────────────────────────────────────┐
│                    Garage S3 on NAS                          │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐      │
│  │   volsync-   │  │    cnpg-     │  │  longhorn-   │      │
│  │   backups    │  │   backups    │  │   backups    │      │
│  └──────────────┘  └──────────────┘  └──────────────┘      │
└─────────────────────────────────────────────────────────────┘
         ▲                   ▲                   ▲
    Volsync              CNPG               Longhorn
 (PVC backups)      (PostgreSQL)        (block snapshots)
```

### Volsync — Application PVC backups

Backs up Longhorn PVCs using Restic with content-defined chunking (deduplication + compression).

| PVC | Schedule | Size |
|-----|----------|------|
| homepage | Daily 3:15 AM | 1Gi |
| home-assistant-config | Daily 2:00 AM | 5Gi |
| nextcloud-html | Daily 1:00 AM | 10Gi |
| forgejo-data | Daily 3:00 AM | 20Gi |
| immich-db | Daily 2:30 AM | 10Gi |
| kavita-config | Daily 3:00 AM | 2Gi |
| grafana | Daily 3:30 AM | 1Gi |

**Retention**: 7 daily, 8 weekly, 6 monthly snapshots (~6 months)  
**Target**: `s3://volsync-backups/`

### CloudNative-PG — PostgreSQL databases

Continuous WAL archiving with periodic base backups. Provides point-in-time recovery to any second within the retention window.

**Retention**: 180 days  
**Target**: `s3://cnpg-backups/<app>-postgres/`

### Longhorn — Block snapshots

Longhorn snapshots are triggered by Volsync before each backup job. The snapshot is sent to `s3://longhorn-backups/` and pruned after the Volsync backup completes.

## Storage Efficiency

All three systems use deduplication — only changed data is stored after the initial backup. Typical multiplier is ~1.8x source size for 6 months of retention, compared to 21x if storing full copies.

## Setup

### 1. Bootstrap Garage

```bash
task storage:bootstrap-garage
```

This creates the `volsync-backups` bucket, generates S3 credentials, and writes them back into `cluster.yaml` automatically (`volsync_s3_access_key`, `volsync_s3_secret_key`).

### 2. Set the Restic password

Add a Restic encryption password to `cluster.yaml` (generate one if not set):

```bash
openssl rand -base64 32
```

```yaml
volsync_restic_password: "<generated-value>"
```

### 3. Render and push

```bash
task configure
git add -A && git commit -m "feat(volsync): enable automated PVC backups"
git push
```

Flux will reconcile and deploy Volsync. ReplicationSources are created for each PVC listed above.

### 4. Trigger and verify first backup

Don't wait for the scheduled time — verify it works immediately:

```bash
# Replace <name> and <namespace> with the ReplicationSource you want to test
kubectl patch replicationsource <name> -n <namespace> \
  --type merge \
  -p "{\"spec\":{\"trigger\":{\"manual\":\"backup-$(date +%Y%m%d-%H%M%S)\"}}}"

# Watch the mover pod
kubectl get pods -n <namespace> -l volsync.backube/replicationsource=<name> -w

# Confirm completion
kubectl get replicationsource <name> -n <namespace> \
  -o jsonpath='{.status.lastSyncTime}'
```

## Monitoring

### Check backup status

```bash
# All ReplicationSources
kubectl get replicationsource -A

# CNPG backups
kubectl get backup -n entertainment -l cnpg.io/cluster=immich-postgres
kubectl get backup -n cloud -l cnpg.io/cluster=nextcloud-postgres
kubectl get backup -n forgejo -l cnpg.io/cluster=forgejo-postgres

# Garage bucket sizes
kubectl exec -n storage garage-0 -- garage bucket info volsync-backups
kubectl exec -n storage garage-0 -- garage bucket info cnpg-backups
```

### List backups in S3

```bash
kubectl port-forward -n storage svc/garage-s3 3900:3900

export AWS_ACCESS_KEY_ID="<your-key>"
export AWS_SECRET_ACCESS_KEY="<your-secret>"
aws s3 ls s3://volsync-backups/ --recursive --endpoint-url http://localhost:3900
aws s3 ls s3://cnpg-backups/ --recursive --endpoint-url http://localhost:3900
```

### Prometheus alerts

Volsync exposes Prometheus metrics when a ServiceMonitor is configured. See the [Volsync monitoring documentation](https://volsync.readthedocs.io/en/stable/usage/metrics/index.html) for current metric names and recommended alert rules.

## Troubleshooting

### "Repository not found"

The first backup initializes the Restic repository automatically. If it fails, check logs:

```bash
kubectl logs -n <namespace> -l volsync.backube/replicationsource=<name>
```

### "Permission denied" on S3

```bash
task storage:bootstrap-garage   # re-grants permissions
task configure
kubectl delete secret <app>-restic-secret -n <namespace>
flux reconcile kustomization <kustomization-name>
```

### Backup job stuck in Pending

```bash
kubectl describe replicationsource <name> -n <namespace>
kubectl get events -n <namespace> --sort-by='.lastTimestamp'
```

Common causes: PVC does not exist, Longhorn snapshot class not found, insufficient resources.
