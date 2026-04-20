#!/usr/bin/env bash
# fix-static-pvs.sh - Rebind PVCs to use static PVs instead of dynamic provisioning

set -euo pipefail

echo "==> Fixing static PV bindings for media services"
echo ""

# List of services to fix
declare -A SERVICES=(
  ["radarr-media"]="downloads:radarr-media:nfs-media-videos"
  ["sonarr-media"]="downloads:sonarr-media:nfs-media-videos"
  ["jellyfin-media"]="entertainment:jellyfin-media:nfs-media-videos"
  ["kavita-books"]="entertainment:kavita-books:kavita-books"
  ["immich-library"]="entertainment:immich-library:immich-library"
)

# Check prerequisites
if ! kubectl version &>/dev/null; then
  echo "Error: kubectl not found or cluster not accessible"
  exit 1
fi

echo "This script will:"
echo "1. Scale down affected deployments"
echo "2. Delete dynamically provisioned PVCs and PVs"
echo "3. Apply static PV/PVC manifests"
echo "4. Scale deployments back up"
echo ""
read -p "Continue? (y/N) " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
  echo "Aborted."
  exit 0
fi

# Step 1: Scale down all affected deployments
echo ""
echo "==> Step 1: Scaling down deployments..."
kubectl scale deployment -n downloads radarr --replicas=0 || true
kubectl scale deployment -n downloads sonarr --replicas=0 || true
kubectl scale deployment -n entertainment jellyfin --replicas=0 || true
kubectl scale deployment -n entertainment kavita --replicas=0 || true
kubectl scale deployment -n entertainment immich-server --replicas=0 || true

echo "Waiting for pods to terminate..."
sleep 10

# Step 2: Delete dynamic PVCs and PVs
echo ""
echo "==> Step 2: Deleting dynamically provisioned PVCs and PVs..."

for service in "${!SERVICES[@]}"; do
  IFS=':' read -r namespace pvc_name pv_name <<< "${SERVICES[$service]}"

  echo "  Processing $pvc_name in namespace $namespace..."

  # Get the dynamically created PV name
  DYNAMIC_PV=$(kubectl get pvc -n "$namespace" "$pvc_name" -o jsonpath='{.spec.volumeName}' 2>/dev/null || echo "")

  if [[ -n "$DYNAMIC_PV" && "$DYNAMIC_PV" == pvc-* ]]; then
    echo "    Found dynamic PV: $DYNAMIC_PV"

    # Delete PVC first
    kubectl delete pvc -n "$namespace" "$pvc_name" --wait=false || true

    # Wait a bit
    sleep 2

    # Delete the dynamic PV
    kubectl delete pv "$DYNAMIC_PV" --wait=false || true
  else
    echo "    PVC already uses static PV or doesn't exist"
  fi
done

echo "Waiting for deletions to complete..."
sleep 15

# Step 3: Apply static PVs and PVCs
echo ""
echo "==> Step 3: Applying static PV/PVC manifests..."

# Apply shared media PV first
echo "  Applying shared nfs-media-videos PV..."
kubectl apply -f kubernetes/apps/storage/nfs-media-pv.yaml

# Apply individual PVCs
echo "  Applying radarr-media PVC..."
kubectl apply -f kubernetes/apps/downloads/radarr/app/media-pvc.yaml

echo "  Applying sonarr-media PVC..."
kubectl apply -f kubernetes/apps/downloads/sonarr/app/media-pvc.yaml

echo "  Applying jellyfin-media PVC..."
kubectl apply -f kubernetes/apps/entertainment/jellyfin/app/media-pvc.yaml

echo "  Applying kavita-books PV and PVC..."
kubectl apply -f kubernetes/apps/entertainment/kavita/app/pvc.yaml

echo "  Applying immich-library PV and PVC..."
kubectl apply -f kubernetes/apps/entertainment/immich/app/pvc.yaml

echo "Waiting for PVCs to bind..."
sleep 5

# Step 4: Verify bindings
echo ""
echo "==> Step 4: Verifying PVC bindings..."

for service in "${!SERVICES[@]}"; do
  IFS=':' read -r namespace pvc_name pv_name <<< "${SERVICES[$service]}"

  STATUS=$(kubectl get pvc -n "$namespace" "$pvc_name" -o jsonpath='{.status.phase}' 2>/dev/null || echo "NotFound")
  VOLUME=$(kubectl get pvc -n "$namespace" "$pvc_name" -o jsonpath='{.spec.volumeName}' 2>/dev/null || echo "")

  if [[ "$STATUS" == "Bound" && "$VOLUME" == "$pv_name" ]]; then
    echo "  ✅ $namespace/$pvc_name -> $pv_name (Bound)"
  else
    echo "  ❌ $namespace/$pvc_name -> $VOLUME (Status: $STATUS)"
  fi
done

# Step 5: Scale deployments back up
echo ""
echo "==> Step 5: Scaling deployments back up..."
kubectl scale deployment -n downloads radarr --replicas=1
kubectl scale deployment -n downloads sonarr --replicas=1
kubectl scale deployment -n entertainment jellyfin --replicas=1
kubectl scale deployment -n entertainment kavita --replicas=1
kubectl scale deployment -n entertainment immich-server --replicas=1

echo ""
echo "==> Done! Verifying pods are starting..."
echo ""
kubectl get pods -n downloads -l app.kubernetes.io/name=radarr
kubectl get pods -n downloads -l app.kubernetes.io/name=sonarr
kubectl get pods -n entertainment -l app.kubernetes.io/name=jellyfin
kubectl get pods -n entertainment -l app.kubernetes.io/name=kavita
kubectl get pods -n entertainment -l app.kubernetes.io/name=immich-server

echo ""
echo "Monitor logs for mount issues:"
echo "  kubectl logs -n downloads -l app.kubernetes.io/name=radarr -f"
echo "  kubectl logs -n downloads -l app.kubernetes.io/name=sonarr -f"
echo "  kubectl logs -n entertainment -l app.kubernetes.io/name=jellyfin -f"
echo "  kubectl logs -n entertainment -l app.kubernetes.io/name=kavita -f"
echo "  kubectl logs -n entertainment -l app.kubernetes.io/name=immich-server -f"
