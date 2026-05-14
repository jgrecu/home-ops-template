#!/usr/bin/env bash
# restore-pvc.sh - Restore a PVC from Volsync backup
# Usage: ./restore-pvc.sh <namespace> <pvc-name> <capacity>

set -Eeuo pipefail

NAMESPACE=${1:-}
PVC_NAME=${2:-}
CAPACITY=${3:-}

if [[ -z "$NAMESPACE" || -z "$PVC_NAME" || -z "$CAPACITY" ]]; then
  echo "Usage: $0 <namespace> <pvc-name> <capacity>"
  echo "Example: $0 forgejo forgejo-data 20Gi"
  exit 1
fi

echo "==> Restoring PVC: $PVC_NAME in namespace $NAMESPACE"

# Check if Volsync secret exists
SECRET_NAME="${PVC_NAME}-restic-secret"
if ! kubectl get secret -n "$NAMESPACE" "$SECRET_NAME" &>/dev/null; then
  echo "Error: Volsync secret not found: $SECRET_NAME"
  echo "This PVC may not have Volsync backups configured."
  exit 1
fi

# Scale down any deployments using this PVC
echo "==> Finding deployments using PVC $PVC_NAME..."
DEPLOYMENTS=$(kubectl get deployment -n "$NAMESPACE" -o json | \
  jq -r --arg pvc "$PVC_NAME" '.items[] | select(.spec.template.spec.volumes[]?.persistentVolumeClaim.claimName == $pvc) | .metadata.name')

if [[ -n "$DEPLOYMENTS" ]]; then
  echo "Found deployments: $DEPLOYMENTS"
  for DEPLOY in $DEPLOYMENTS; do
    echo "Scaling down deployment: $DEPLOY"
    kubectl scale deployment -n "$NAMESPACE" "$DEPLOY" --replicas=0
  done

  # Wait for pods to terminate
  echo "Waiting for pods to terminate..."
  sleep 5
else
  echo "No deployments found using this PVC"
fi

# Check if PVC exists
if kubectl get pvc -n "$NAMESPACE" "$PVC_NAME" &>/dev/null; then
  echo "==> PVC exists. Deleting it to restore from backup..."
  kubectl delete pvc -n "$NAMESPACE" "$PVC_NAME"

  # Wait for deletion
  echo "Waiting for PVC deletion..."
  kubectl wait --for=delete pvc/"$PVC_NAME" -n "$NAMESPACE" --timeout=120s || true
fi

# Create ReplicationDestination
echo "==> Creating ReplicationDestination for restore..."
cat <<EOF | kubectl apply -f -
apiVersion: volsync.backube/v1alpha1
kind: ReplicationDestination
metadata:
  name: ${PVC_NAME}-restore
  namespace: ${NAMESPACE}
spec:
  trigger:
    manual: restore-$(date +%s)
  restic:
    repository: ${SECRET_NAME}
    destinationPVC: ${PVC_NAME}
    storageClassName: longhorn
    accessModes:
      - ReadWriteOnce
    capacity: ${CAPACITY}
    copyMethod: Direct
EOF

# Wait for restore to complete
echo "==> Waiting for restore to complete (this may take several minutes)..."
if kubectl wait --for=condition=complete replicationdestination/"${PVC_NAME}-restore" -n "$NAMESPACE" --timeout=600s; then
  echo "✅ Restore completed successfully!"
else
  echo "❌ Restore failed or timed out"
  kubectl describe replicationdestination/"${PVC_NAME}-restore" -n "$NAMESPACE"
  exit 1
fi

# Clean up ReplicationDestination
echo "==> Cleaning up ReplicationDestination..."
kubectl delete replicationdestination/"${PVC_NAME}-restore" -n "$NAMESPACE"

# Scale deployments back up
if [[ -n "$DEPLOYMENTS" ]]; then
  echo "==> Scaling deployments back up..."
  for DEPLOY in $DEPLOYMENTS; do
    echo "Scaling up deployment: $DEPLOY"
    kubectl scale deployment -n "$NAMESPACE" "$DEPLOY" --replicas=1
  done
fi

echo ""
echo "✅ PVC restore complete!"
echo "   Namespace: $NAMESPACE"
echo "   PVC: $PVC_NAME"
echo "   Capacity: $CAPACITY"
echo ""
echo "Verify the restored data:"
echo "  kubectl exec -n $NAMESPACE <pod-name> -- ls -la /path/to/mount"
