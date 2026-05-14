#!/usr/bin/env bash
set -Eeuo pipefail

# Bootstrap SeaweedFS S3 storage for Kubernetes cluster backups
#
# This script automates:
# - Creating S3 buckets (longhorn-backups, cnpg-backups, volsync-backups)
# - Generating S3 access credentials
# - Updating cluster.yaml with credentials
#
# Prerequisites:
# - SeaweedFS pods must be running in storage namespace
# - kubectl access to the cluster

source "$(dirname "${0}")/lib/common.sh"

export LOG_LEVEL="${LOG_LEVEL:-info}"
export ROOT_DIR="$(git rev-parse --show-toplevel)"
export PORT_FORWARD_PID=""

# Cleanup function
function cleanup() {
    if [[ -n "${PORT_FORWARD_PID}" ]]; then
        log debug "Cleaning up port-forward" "pid=${PORT_FORWARD_PID}"
        kill "${PORT_FORWARD_PID}" 2>/dev/null || true
        wait "${PORT_FORWARD_PID}" 2>/dev/null || true
    fi
}

trap cleanup EXIT

# Check prerequisites
function check_prerequisites() {
    log debug "Checking prerequisites"
    check_cli "kubectl" "jq" "curl"

    # Check if seaweedfs filer pod is running
    if ! kubectl get pod -n storage -l app.kubernetes.io/name=seaweedfs,app.kubernetes.io/component=filer -o name | grep -q pod; then
        log error "SeaweedFS filer pod not found" "namespace=storage"
    fi

    # Check if filer is ready
    local filer_pod
    filer_pod=$(kubectl get pod -n storage -l app.kubernetes.io/name=seaweedfs,app.kubernetes.io/component=filer -o jsonpath='{.items[0].metadata.name}')
    if ! kubectl get pod -n storage "${filer_pod}" -o jsonpath='{.status.phase}' | grep -q "Running"; then
        log error "SeaweedFS filer pod is not running" "pod=${filer_pod}"
    fi

    log info "Prerequisites check passed"
}

# Start port-forward to SeaweedFS S3 API
function start_port_forward() {
    log debug "Starting port-forward to SeaweedFS S3 API"

    kubectl port-forward -n storage svc/seaweedfs-filer 8333:8333 >/dev/null 2>&1 &
    PORT_FORWARD_PID=$!

    # Wait for port-forward to be ready
    sleep 3

    # Verify port-forward is working
    if ! kill -0 "${PORT_FORWARD_PID}" 2>/dev/null; then
        log error "Port-forward failed to start"
    fi

    # Test connection with retry
    local retries=0
    while [[ $retries -lt 5 ]]; do
        if curl -s -f http://localhost:8333/ >/dev/null 2>&1; then
            log debug "Port-forward ready" "pid=${PORT_FORWARD_PID}"
            return 0
        fi
        log debug "Waiting for port-forward to be ready..." "retry=$((retries+1))"
        sleep 2
        ((retries++))
    done

    log error "Port-forward connection test failed after retries"
}

# Create S3 bucket using weed shell
function create_bucket() {
    local bucket_name="${1}"
    local filer_pod

    filer_pod=$(kubectl get pod -n storage -l app.kubernetes.io/name=seaweedfs,app.kubernetes.io/component=filer -o jsonpath='{.items[0].metadata.name}')

    log info "Creating bucket" "bucket=${bucket_name}"

    # Create bucket directory in filer
    # SeaweedFS S3 buckets are directories under /buckets/
    kubectl exec -n storage "${filer_pod}" -- \
        sh -c "weed shell -master seaweedfs-master:9333 <<EOF
fs.mkdir /buckets/${bucket_name}
EOF" 2>/dev/null || true

    log info "Bucket created" "bucket=${bucket_name}"
}

# List buckets
function list_buckets() {
    local filer_pod
    filer_pod=$(kubectl get pod -n storage -l app.kubernetes.io/name=seaweedfs,app.kubernetes.io/component=filer -o jsonpath='{.items[0].metadata.name}')

    kubectl exec -n storage "${filer_pod}" -- \
        sh -c "weed shell -master seaweedfs-master:9333 <<EOF
fs.ls /buckets/
EOF" 2>/dev/null | grep -oE '\[[^]]+\]' | tr -d '[]' || echo ""
}

# Generate S3 credentials
# SeaweedFS uses static credentials configured in the S3 config or via IAM
function generate_credentials() {
    log info "Generating S3 credentials"

    # Generate random access key and secret
    local access_key_id
    local secret_access_key

    access_key_id="SWFS$(openssl rand -hex 10 | tr '[:lower:]' '[:upper:]')"
    secret_access_key=$(openssl rand -hex 32)

    echo "${access_key_id}:${secret_access_key}"
}

# Configure S3 authentication in SeaweedFS
function configure_s3_auth() {
    local access_key_id="${1}"
    local secret_access_key="${2}"
    local filer_pod

    filer_pod=$(kubectl get pod -n storage -l app.kubernetes.io/name=seaweedfs,app.kubernetes.io/component=filer -o jsonpath='{.items[0].metadata.name}')

    log info "Configuring S3 authentication"

    # Configure S3 auth via weed shell
    kubectl exec -n storage "${filer_pod}" -- \
        sh -c "weed shell -master seaweedfs-master:9333 <<EOF
s3.configure -apply -user home-lab -access_key ${access_key_id} -secret_key ${secret_access_key} -actions Read,Write,List,Tagging,Admin
EOF" 2>/dev/null || true

    log info "S3 authentication configured"
}

# Update cluster.yaml with S3 credentials
function update_cluster_config() {
    local access_key_id="${1}"
    local secret_access_key="${2}"

    log info "Updating cluster.yaml with S3 credentials"

    local cluster_yaml="${ROOT_DIR}/cluster.yaml"

    if [[ ! -f "${cluster_yaml}" ]]; then
        log error "cluster.yaml not found" "path=${cluster_yaml}"
    fi

    # Create a backup
    cp "${cluster_yaml}" "${cluster_yaml}.bak"
    log debug "Created backup" "file=${cluster_yaml}.bak"

    # Update credentials using sed
    if [[ "$(uname)" == "Darwin" ]]; then
        sed -i '' "s|^seaweedfs_s3_access_key_id:.*|seaweedfs_s3_access_key_id: \"${access_key_id}\"|" "${cluster_yaml}"
        sed -i '' "s|^seaweedfs_s3_secret_access_key:.*|seaweedfs_s3_secret_access_key: \"${secret_access_key}\"|" "${cluster_yaml}"
        # Also update Volsync credentials to use the same SeaweedFS key
        sed -i '' "s|^volsync_s3_access_key:.*|volsync_s3_access_key: \"${access_key_id}\"|" "${cluster_yaml}"
        sed -i '' "s|^volsync_s3_secret_key:.*|volsync_s3_secret_key: \"${secret_access_key}\"|" "${cluster_yaml}"
    else
        sed -i "s|^seaweedfs_s3_access_key_id:.*|seaweedfs_s3_access_key_id: \"${access_key_id}\"|" "${cluster_yaml}"
        sed -i "s|^seaweedfs_s3_secret_access_key:.*|seaweedfs_s3_secret_access_key: \"${secret_access_key}\"|" "${cluster_yaml}"
        # Also update Volsync credentials to use the same SeaweedFS key
        sed -i "s|^volsync_s3_access_key:.*|volsync_s3_access_key: \"${access_key_id}\"|" "${cluster_yaml}"
        sed -i "s|^volsync_s3_secret_key:.*|volsync_s3_secret_key: \"${secret_access_key}\"|" "${cluster_yaml}"
    fi

    log info "cluster.yaml updated successfully"
}

# Main bootstrap function
function main() {
    log info "Starting SeaweedFS S3 bootstrap"

    check_prerequisites

    # Start port-forward
    start_port_forward

    # Create required buckets
    local required_buckets=("longhorn-backups" "cnpg-backups" "volsync-backups")

    for bucket in "${required_buckets[@]}"; do
        create_bucket "${bucket}"
    done

    # Check if credentials already exist in cluster.yaml
    local existing_key
    existing_key=$(grep "^seaweedfs_s3_access_key_id:" "${ROOT_DIR}/cluster.yaml" | sed -E 's/^[^:]+:[[:space:]]*"?([^"]*)"?$/\1/' || echo "")

    if [[ -n "${existing_key}" ]]; then
        log info "S3 credentials already configured in cluster.yaml" "access_key_id=${existing_key}"
        log info "To regenerate, clear seaweedfs_s3_access_key_id in cluster.yaml and run again"
    else
        # Generate new credentials
        local credentials
        credentials=$(generate_credentials)
        local access_key_id="${credentials%%:*}"
        local secret_access_key="${credentials##*:}"

        log info "Generated new S3 credentials" "access_key_id=${access_key_id}"

        # Configure S3 auth
        configure_s3_auth "${access_key_id}" "${secret_access_key}"

        # Update cluster.yaml
        update_cluster_config "${access_key_id}" "${secret_access_key}"
    fi

    log info "SeaweedFS S3 bootstrap completed successfully"
    log info ""
    log info "Next steps:"
    log info "  1. Run: task configure --yes"
    log info "  2. Commit changes: git add -A && git commit -m 'feat(seaweedfs): bootstrap S3 credentials'"
    log info "  3. Push: git push"
    log info ""
    log info "Flux will reconcile and deploy the backup secrets automatically."
}

# Run main function
main "$@"
