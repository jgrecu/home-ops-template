# Disaster Recovery

## What happens when you delete a namespace

Flux recreates the namespace and all Kubernetes resources within 1–5 minutes. However, **PVCs are recreated empty** — Volsync does not automatically restore data. You must trigger a restore manually.

This is intentional: the system cannot distinguish between an accidental deletion, an intentional reset, or a migration. Manual restore gives you control over which snapshot to restore and lets you verify backup integrity first.

## Quick restore

```bash
task storage:restore-pvc -- <namespace> <pvc-name> <capacity>

# Examples
task storage:restore-pvc -- forgejo forgejo-data 20Gi
task storage:restore-pvc -- entertainment immich-db 10Gi
task storage:restore-pvc -- cloud nextcloud-html 10Gi
task storage:restore-pvc -- default homepage 1Gi
```

The task scales the app down, deletes the empty PVC, triggers a Volsync ReplicationDestination, waits for completion, and scales back up. Typically 5–15 minutes.

## Manual restore (step by step)

Use this when you need more control (e.g., restoring to a specific point in time or a separate PVC).

### Step 1: Scale down the app

```bash
kubectl scale deployment <app-name> -n <namespace> --replicas=0
kubectl wait --for=delete pod -l app.kubernetes.io/name=<app-name> -n <namespace> --timeout=60s
```

### Step 2: Delete the empty PVC

```bash
kubectl delete pvc -n <namespace> <pvc-name>
```

### Step 3: Create a ReplicationDestination

```bash
kubectl apply -f - <<EOF
apiVersion: volsync.backube/v1alpha1
kind: ReplicationDestination
metadata:
  name: <pvc-name>-restore
  namespace: <namespace>
spec:
  trigger:
    manual: restore-$(date +%s)
  restic:
    repository: <pvc-name>-restic-secret
    destinationPVC: <pvc-name>
    storageClassName: longhorn
    accessModes:
      - ReadWriteOnce
    capacity: <capacity>
    copyMethod: Direct
    # restoreAsOf: "2026-04-15T02:30:00Z"  # optional: specific snapshot
EOF
```

### Step 4: Wait for completion

```bash
kubectl wait replicationdestination/<pvc-name>-restore -n <namespace> \
  --for=jsonpath='{.status.latestMoverStatus.result}'=Succeeded \
  --timeout=600s
```

### Step 5: Clean up and restart

```bash
kubectl delete replicationdestination -n <namespace> <pvc-name>-restore
kubectl scale deployment -n <namespace> <app-name> --replicas=1
```

## Common scenarios

### Accidentally deleted a namespace

```bash
# Find the Flux kustomization name
flux get kustomizations

# Force immediate reconciliation
flux reconcile kustomization <kustomization-name> --with-source

# Wait for pods to start (they have empty data), then restore PVCs
task storage:restore-pvc -- forgejo forgejo-data 20Gi
```

CNPG will attempt automatic database recovery from Garage on startup. If it fails, see database recovery below.

**RTO**: 10–20 min | **RPO**: last backup (max 24h)

### Corrupted PVC

```bash
kubectl scale deployment -n <namespace> <app-name> --replicas=0
kubectl delete pvc -n <namespace> <pvc-name>
task storage:restore-pvc -- <namespace> <pvc-name> <size>
```

**RTO**: 15–30 min | **RPO**: last backup (max 24h)

### Corrupted PostgreSQL database

CNPG supports point-in-time recovery via WAL archives. Find the primary pod:

```bash
kubectl get pod -n <namespace> -l cnpg.io/cluster=<app>-postgres,role=primary
```

For full PITR, the CNPG cluster must be recreated with a `bootstrap.recovery` spec pointing to the Garage backup. See [CNPG documentation](https://cloudnative-pg.io/documentation/).

Alternatively, if the DB PVC is backed by Volsync:

```bash
task storage:restore-pvc -- <namespace> <app>-db <size>
```

**RTO**: 30–60 min | **RPO**: last WAL archive (<5 min for CNPG, last backup for Volsync)

### Complete cluster loss

1. Rebuild the Talos cluster (same network config)
2. Bootstrap apps via Flux
3. Bootstrap Garage (reconnects to existing NAS data):
   ```bash
   task storage:bootstrap-garage
   ```
4. Restore all PVCs in dependency order:
   ```bash
   task storage:restore-pvc -- default homepage 1Gi
   task storage:restore-pvc -- observability grafana 1Gi
   task storage:restore-pvc -- forgejo forgejo-data 20Gi
   task storage:restore-pvc -- cloud nextcloud-html 10Gi
   task storage:restore-pvc -- entertainment immich-db 10Gi
   task storage:restore-pvc -- entertainment kavita-config 2Gi
   task storage:restore-pvc -- home-automation home-assistant-config 5Gi
   ```
   CNPG databases recover automatically from Garage on cluster startup.

**RTO**: 4–8 hours | **RPO**: last backup (max 24h for PVCs, <5 min for databases)

### Garage / NAS loss

There is no backup of backups. If Garage data is lost, PVC and database history is unrecoverable. Mitigate with NAS-level RAID and snapshots, or configure a secondary offsite S3 target.

## Surgical file recovery

To recover specific files without a full PVC restore:

```bash
# 1. Restore to a temporary PVC
kubectl apply -f - <<EOF
apiVersion: volsync.backube/v1alpha1
kind: ReplicationDestination
metadata:
  name: <app>-restore-temp
  namespace: <namespace>
spec:
  trigger:
    manual: restore-$(date +%s)
  restic:
    repository: <app>-restic-secret
    destinationPVC: <app>-restored-temp
    storageClassName: longhorn
    accessModes: [ReadWriteOnce]
    capacity: <size>
    copyMethod: Direct
EOF

# 2. Wait for completion
kubectl wait replicationdestination/<app>-restore-temp -n <namespace> \
  --for=jsonpath='{.status.latestMoverStatus.result}'=Succeeded \
  --timeout=600s

# 3. Mount both PVCs and copy specific files
kubectl run -n <namespace> file-recovery --image=alpine --rm -it \
  --overrides='{
    "spec": {
      "containers": [{
        "name": "recovery", "image": "alpine", "command": ["sh"],
        "stdin": true, "tty": true,
        "volumeMounts": [
          {"name": "live", "mountPath": "/live"},
          {"name": "restored", "mountPath": "/restored"}
        ]
      }],
      "volumes": [
        {"name": "live", "persistentVolumeClaim": {"claimName": "<live-pvc-name>"}},
        {"name": "restored", "persistentVolumeClaim": {"claimName": "<app>-restored-temp"}}
      ]
    }
  }'

# Inside the pod:
# cp -a /restored/path/to/file /live/path/to/

# 4. Clean up
kubectl delete pvc -n <namespace> <app>-restored-temp
kubectl delete replicationdestination -n <namespace> <app>-restore-temp
```

## Testing backups

Never assume backups work — test them regularly.

```bash
kubectl create namespace backup-test

# Copy the Restic secret into the test namespace
kubectl get secret <app>-restic-secret -n <namespace> -o yaml \
  | sed -e '/^\s*namespace:/d' -e '/^\s*resourceVersion:/d' \
        -e '/^\s*uid:/d' -e '/^\s*creationTimestamp:/d' \
  | kubectl apply -n backup-test -f -

kubectl apply -f - <<EOF
apiVersion: volsync.backube/v1alpha1
kind: ReplicationDestination
metadata:
  name: test-restore
  namespace: backup-test
spec:
  trigger:
    manual: test-$(date +%s)
  restic:
    repository: <app>-restic-secret
    destinationPVC: test-data
    storageClassName: longhorn
    accessModes: [ReadWriteOnce]
    capacity: <size>
    copyMethod: Direct
EOF

kubectl wait replicationdestination/test-restore -n backup-test \
  --for=jsonpath='{.status.latestMoverStatus.result}'=Succeeded \
  --timeout=600s

kubectl run -n backup-test verify --image=busybox --rm -it --restart=Never \
  --overrides='{"spec":{"containers":[{"name":"v","image":"busybox","command":["/bin/sh"],"stdin":true,"tty":true,"volumeMounts":[{"name":"d","mountPath":"/data"}]}],"volumes":[{"name":"d","persistentVolumeClaim":{"claimName":"test-data"}}]}}' \
  -- ls -la /data

kubectl delete namespace backup-test
```

For backup status monitoring commands, see [BACKUPS.md](./BACKUPS.md#monitoring).
