#!/usr/bin/env bash
set -Eeuo pipefail

# Bootstrap Garage S3 storage for Kubernetes cluster backups
#
# This script automates:
# - Initializing Garage cluster layout
# - Creating S3 buckets (longhorn-backups, cnpg-backups)
# - Generating S3 access keys
# - Granting bucket permissions to keys
# - Updating cluster.yaml with credentials
#
# IMPORTANT: Requires Garage v2.x for automatic permission granting
# The /v2/AllowBucketKey API endpoint is not available in v1.x

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
    rm -f /tmp/garage_*.json 2>/dev/null || true
}

trap cleanup EXIT

# Check prerequisites
function check_prerequisites() {
    log debug "Checking prerequisites"
    check_cli "kubectl" "jq" "curl"

    # Check if garage pod is running
    if ! kubectl get pod -n storage garage-0 &>/dev/null; then
        log error "Garage pod not found" "pod=garage-0" "namespace=storage"
    fi

    # Check if garage is ready
    if ! kubectl get pod -n storage garage-0 -o jsonpath='{.status.phase}' | grep -q "Running"; then
        log error "Garage pod is not running" "pod=garage-0"
    fi

    log info "Prerequisites check passed"
}

# Get garage admin token from secret
function get_admin_token() {
    log debug "Retrieving garage admin token"

    local garage_toml
    garage_toml=$(kubectl get secret -n storage garage-config -o jsonpath='{.data.garage\.toml}' | base64 -d 2>/dev/null)

    if [[ -z "${garage_toml}" ]]; then
        log error "Failed to retrieve garage config" "secret=garage-config"
    fi

    # Extract admin_token from TOML (format: admin_token = "token_value")
    local token
    token=$(echo "${garage_toml}" | grep 'admin_token' | sed 's/.*admin_token = "\(.*\)".*/\1/' | tr -d '\n\r')

    if [[ -z "${token}" ]]; then
        log error "Failed to extract admin token from garage.toml"
    fi

    echo "${token}"
}

# Start port-forward to garage admin API
function start_port_forward() {
    log debug "Starting port-forward to garage admin API"

    kubectl port-forward -n storage svc/garage-admin 3903:3903 >/dev/null 2>&1 &
    PORT_FORWARD_PID=$!

    # Wait for port-forward to be ready (increased timeout)
    sleep 5

    # Verify port-forward is working
    if ! kill -0 "${PORT_FORWARD_PID}" 2>/dev/null; then
        log error "Port-forward failed to start"
    fi

    # Test connection with retry
    local retries=0
    while [[ $retries -lt 3 ]]; do
        if curl -s -f -H "Authorization: Bearer ${GARAGE_ADMIN_TOKEN}" http://localhost:3903/v2/GetClusterStatus >/dev/null 2>&1; then
            log debug "Port-forward ready" "pid=${PORT_FORWARD_PID}"
            return 0
        fi
        log debug "Waiting for port-forward to be ready..." "retry=$((retries+1))"
        sleep 2
        ((retries++))
    done

    log error "Port-forward connection test failed after retries"
}

# Call garage admin API
function garage_api() {
    local method="${1}"
    local endpoint="${2}"
    local data="${3:-}"
    local token="${GARAGE_ADMIN_TOKEN}"
    local url="http://localhost:3903${endpoint}"

    log debug "API call" "method=${method}" "endpoint=${endpoint}"

    local temp_file="/tmp/garage_response_$$.json"

    # Make the API call
    local http_code
    if [[ -n "${data}" ]]; then
        http_code=$(curl -s -o "${temp_file}" -w "%{http_code}" \
            -X "${method}" \
            -H "Authorization: Bearer ${token}" \
            -H "Content-Type: application/json" \
            -d "${data}" \
            "${url}")
    else
        http_code=$(curl -s -o "${temp_file}" -w "%{http_code}" \
            -X "${method}" \
            -H "Authorization: Bearer ${token}" \
            "${url}")
    fi

    local response
    response=$(cat "${temp_file}" 2>/dev/null || echo "")
    rm -f "${temp_file}"

    # Check for success
    if [[ "${http_code}" != "200" ]] && [[ "${http_code}" != "204" ]]; then
        log error "API call failed" "method=${method}" "endpoint=${endpoint}" "http_code=${http_code}" "response=${response:0:200}"
    fi

    echo "${response}"
}

# Get cluster layout
function get_layout() {
    garage_api "GET" "/v2/GetClusterLayout"
}

# Get node ID
function get_node_id() {
    local status
    status=$(garage_api "GET" "/v2/GetClusterStatus")
    echo "${status}" | jq -r '.nodes[0].id // empty'
}

# Check if cluster is initialized
function is_initialized() {
    local layout
    layout=$(get_layout)

    local version
    version=$(echo "${layout}" | jq -r '.version // 0')

    if [[ "${version}" -gt 0 ]]; then
        log debug "Cluster is initialized" "layout_version=${version}"
        return 0
    else
        log debug "Cluster not initialized" "layout_version=${version}"
        return 1
    fi
}

# Initialize garage cluster layout
function init_layout() {
    log info "Initializing garage cluster layout"

    local node_id
    node_id=$(get_node_id)

    if [[ -z "${node_id}" ]]; then
        log error "Failed to get garage node ID"
    fi

    log debug "Got garage node ID" "node_id=${node_id}"

    # Use garage CLI to assign layout
    kubectl exec -n storage garage-0 -- /garage layout assign -z dc1 -c 100G "${node_id}" >/dev/null 2>&1
    log info "Layout assigned to node" "node_id=${node_id}" "zone=dc1" "capacity=100GB"

    # Apply layout
    kubectl exec -n storage garage-0 -- /garage layout apply --version 1 >/dev/null 2>&1
    log info "Layout applied successfully" "version=1"
}

# List buckets
function list_buckets() {
    local buckets
    buckets=$(garage_api "GET" "/v2/ListBuckets")
    echo "${buckets}" | jq -r '.[].globalAliases[]? // empty'
}

# Get bucket ID by name
function get_bucket_id() {
    local bucket_name="${1}"
    local buckets
    buckets=$(garage_api "GET" "/v2/ListBuckets")
    echo "${buckets}" | jq -r ".[] | select(.globalAliases[]? == \"${bucket_name}\") | .id // empty" | head -1
}

# Create bucket
function create_bucket() {
    local bucket_name="${1}"

    log info "Creating bucket" "bucket=${bucket_name}"

    local payload
    payload=$(jq -n \
        --arg name "${bucket_name}" \
        '{
            "globalAlias": $name
        }')

    # Try to create bucket
    local temp_file="/tmp/garage_bucket_$$.json"
    local http_code
    http_code=$(curl -s -o "${temp_file}" -w "%{http_code}" \
        -X "POST" \
        -H "Authorization: Bearer ${GARAGE_ADMIN_TOKEN}" \
        -H "Content-Type: application/json" \
        -d "${payload}" \
        "http://localhost:3903/v2/CreateBucket")

    local response
    response=$(cat "${temp_file}" 2>/dev/null || echo "")
    rm -f "${temp_file}"

    if [[ "${http_code}" == "200" ]]; then
        local bucket_id
        bucket_id=$(echo "${response}" | jq -r '.id')
        log info "Bucket created" "bucket=${bucket_name}" "id=${bucket_id}"
    elif [[ "${http_code}" == "409" ]]; then
        log info "Bucket already exists" "bucket=${bucket_name}"
    else
        log error "Failed to create bucket" "http_code=${http_code}" "response=${response}"
    fi
}

# List keys
function list_keys() {
    local keys
    keys=$(garage_api "GET" "/v2/ListKeys")
    echo "${keys}" | jq -r '.[].name // empty'
}

# Get key info by name
function get_key_info() {
    local key_name="${1}"

    # List all keys and find by name
    local keys
    keys=$(garage_api "GET" "/v2/ListKeys")

    local key_id
    key_id=$(echo "${keys}" | jq -r ".[] | select(.name == \"${key_name}\") | .id // empty" | head -1)

    if [[ -z "${key_id}" ]]; then
        return 1
    fi

    # Get full key info (but secretAccessKey is not returned for existing keys)
    garage_api "GET" "/v2/GetKeyInfo?id=${key_id}"
}

# Create key
function create_key() {
    local key_name="${1}"

    local payload
    payload=$(jq -n \
        --arg name "${key_name}" \
        '{
            "name": $name
        }')

    local key_info
    key_info=$(garage_api "POST" "/v2/CreateKey" "${payload}")

    echo "${key_info}"
}

# Grant bucket permissions to key (Garage v2.x API)
function grant_permissions() {
    local bucket_name="${1}"
    local access_key_id="${2}"

    log info "Granting permissions to key" "bucket=${bucket_name} key=${access_key_id}"

    # Get bucket ID from bucket name
    local bucket_id
    bucket_id=$(get_bucket_id "${bucket_name}")

    if [[ -z "${bucket_id}" ]]; then
        log error "Cannot grant permissions: bucket not found" "bucket=${bucket_name}"
        return 1
    fi

    # Garage v2.x uses /v2/AllowBucketKey endpoint
    local payload
    payload=$(jq -n \
        --arg bucketId "${bucket_id}" \
        --arg accessKeyId "${access_key_id}" \
        '{
            "bucketId": $bucketId,
            "accessKeyId": $accessKeyId,
            "permissions": {
                "read": true,
                "write": true,
                "owner": true
            }
        }')

    garage_api "POST" "/v2/AllowBucketKey" "${payload}" >/dev/null

    log info "Permissions granted successfully" "bucket=${bucket_name}"
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
        # macOS sed requires -i with empty string
        sed -i '' "s|^garage_s3_access_key_id:.*|garage_s3_access_key_id: \"${access_key_id}\"|" "${cluster_yaml}"
        sed -i '' "s|^garage_s3_secret_access_key:.*|garage_s3_secret_access_key: \"${secret_access_key}\"|" "${cluster_yaml}"
        sed -i '' "s|^volsync_s3_access_key:.*|volsync_s3_access_key: \"${access_key_id}\"|" "${cluster_yaml}"
        sed -i '' "s|^volsync_s3_secret_key:.*|volsync_s3_secret_key: \"${secret_access_key}\"|" "${cluster_yaml}"
    else
        # Linux sed
        sed -i "s|^garage_s3_access_key_id:.*|garage_s3_access_key_id: \"${access_key_id}\"|" "${cluster_yaml}"
        sed -i "s|^garage_s3_secret_access_key:.*|garage_s3_secret_access_key: \"${secret_access_key}\"|" "${cluster_yaml}"
        sed -i "s|^volsync_s3_access_key:.*|volsync_s3_access_key: \"${access_key_id}\"|" "${cluster_yaml}"
        sed -i "s|^volsync_s3_secret_key:.*|volsync_s3_secret_key: \"${secret_access_key}\"|" "${cluster_yaml}"
    fi

    log info "cluster.yaml updated successfully"
    log warn "You need to run 'task configure' to regenerate templates with new credentials"
}

# Main bootstrap function
function main() {
    log info "Starting Garage S3 bootstrap"

    check_prerequisites

    # Get admin token
    GARAGE_ADMIN_TOKEN=$(get_admin_token)
    export GARAGE_ADMIN_TOKEN

    # Start port-forward
    start_port_forward

    # Check if already initialized
    if is_initialized; then
        log info "Garage cluster already initialized, checking configuration"
    else
        log info "Garage cluster not initialized, starting bootstrap"
        init_layout

        # Wait for layout to be applied
        log info "Waiting for layout to stabilize..."
        sleep 5
    fi

    # Create required buckets
    local required_buckets=("longhorn-backups" "cnpg-backups" "volsync-backups")
    local existing_buckets
    existing_buckets=$(list_buckets)

    for bucket in "${required_buckets[@]}"; do
        if echo "${existing_buckets}" | grep -q "^${bucket}$"; then
            log info "Bucket already exists" "bucket=${bucket}"
        else
            create_bucket "${bucket}"
        fi
    done

    # Create or get S3 key
    local key_name="home-lab"
    local key_info
    local access_key_id
    local secret_access_key

    if key_info=$(get_key_info "${key_name}" 2>/dev/null); then
        log info "S3 key already exists" "key=${key_name}"
        access_key_id=$(echo "${key_info}" | jq -r '.accessKeyId')

        # Secret is not returned for existing keys - check if already in cluster.yaml
        if grep -q "^garage_s3_access_key_id: \"${access_key_id}\"" "${ROOT_DIR}/cluster.yaml" 2>/dev/null; then
            log info "S3 credentials already configured in cluster.yaml"
            secret_access_key=$(grep "^garage_s3_secret_access_key:" "${ROOT_DIR}/cluster.yaml" | sed 's/.*: "\(.*\)".*/\1/')

            if [[ -z "${secret_access_key}" ]] || [[ "${secret_access_key}" == "" ]]; then
                log warn "S3 key exists but secret is not in cluster.yaml"
                log info "Key already exists, cannot retrieve secret. Skipping credential update."
                log info "If you need new credentials, delete the key and run this script again"
                # Don't exit - still need to grant permissions
            fi
        else
            log warn "S3 key exists but credentials don't match cluster.yaml"
            log info "Key already exists, cannot retrieve secret. Skipping credential update."
            log info "If you need new credentials, delete the key and run this script again"
            # Don't exit - still need to grant permissions
        fi
    else
        log info "Creating new S3 key" "key=${key_name}"
        key_info=$(create_key "${key_name}")
        access_key_id=$(echo "${key_info}" | jq -r '.accessKeyId')
        secret_access_key=$(echo "${key_info}" | jq -r '.secretAccessKey')
        log info "S3 key created" "access_key_id=${access_key_id}"

        # Update cluster.yaml with new credentials
        update_cluster_config "${access_key_id}" "${secret_access_key}"
    fi

    # Grant permissions to all buckets (Garage v2.x supports this via API)
    log info "Granting bucket permissions to key" "key=${key_name}"
    for bucket in "${required_buckets[@]}"; do
        grant_permissions "${bucket}" "${access_key_id}"
    done

    log info "Garage S3 bootstrap completed successfully"

    if [[ -n "${secret_access_key:-}" ]] && [[ "${secret_access_key}" != "" ]]; then
        log info "Next steps:"
        log info "  1. Run: task configure"
        log info "  2. Commit changes: git add kubernetes/"
        log info "  3. Push: git push"
    else
        log info "Permissions updated. No configuration changes needed."
    fi
}

# Run main function
main "$@"
