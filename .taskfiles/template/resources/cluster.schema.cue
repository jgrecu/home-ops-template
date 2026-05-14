package config

import (
	"net"
)

#Config: {
	node_cidr: net.IPCIDR & !=cluster_pod_cidr & !=cluster_svc_cidr
	node_dns_servers?: [...net.IPv4]
	node_ntp_servers?: [...net.IPv4]
	node_default_gateway?: net.IPv4 & !=""
	node_vlan_tag?: string & !=""
	cluster_pod_cidr: *"10.42.0.0/16" | net.IPCIDR & !=node_cidr & !=cluster_svc_cidr
	cluster_svc_cidr: *"10.43.0.0/16" | net.IPCIDR & !=node_cidr & !=cluster_pod_cidr
	cluster_api_addr: net.IPv4
	cluster_api_tls_sans?: [...net.FQDN]
	cluster_gateway_addr: net.IPv4 & !=cluster_api_addr & !=cluster_dns_gateway_addr & !=cloudflare_gateway_addr
	cluster_dns_gateway_addr: net.IPv4 & !=cluster_api_addr & !=cluster_gateway_addr & !=cloudflare_gateway_addr
	repository_name: string
	repository_branch?: string & !=""
	repository_visibility?: *"public" | "private"
	cloudflare_domain: net.FQDN
	cloudflare_token: string
	cloudflare_gateway_addr: net.IPv4 & !=cluster_api_addr & !=cluster_gateway_addr & !=cluster_dns_gateway_addr
	// Pi-hole Configuration
	pihole_dns_addr?:        net.IPv4 & !=""
	pihole_admin_password?:  string & !=""
	// Transmission Configuration
	transmission_peer_addr?: net.IPv4 & !=""
	// WireGuard Easy Configuration
	wg_easy_vpn_addr?:         net.IPv4 & !=""
	wg_easy_admin_password?:   string & !=""
	wg_easy_external_host?:    string & !=""
	wg_easy_server_private_key?: string & !=""
	// Grafana Configuration
	grafana_admin_password?: string & !=""
	// Cilium Configuration
	cilium_bgp_router_addr?: net.IPv4 & !=""
	cilium_bgp_router_asn?: string & !=""
	cilium_bgp_node_asn?: string & !=""
	cilium_loadbalancer_mode?: *"dsr" | "snat"
	// NFS Storage Configuration
	nfs_server_addr?:           net.IPv4 & !=""
	nfs_server_path?:           string & !=""
	nfs_media_path?:            string & !=""
	nfs_photos_path?:           string & !=""
	nfs_books_path?:            string & !=""
	nfs_seaweedfs_path?:        string & !=""
	nfs_nextcloud_path?:        string & !=""
	// SeaweedFS S3 Configuration
	seaweedfs_s3_access_key_id?:       string
	seaweedfs_s3_secret_access_key?:   string
	// Forgejo Configuration
	forgejo_admin_email?:           string
	forgejo_admin_password?:        string
	forgejo_runner_secret?:         string
	// Woodpecker CI Configuration
	woodpecker_admin_user?:         string
	woodpecker_oauth_client_id?:    string
	woodpecker_oauth_client_secret?: string
	woodpecker_agent_secret?:       string
	// Recyclarr Configuration
	radarr_api_key?:                string
	recyclarr_radarr_api_key?:      string
	sonarr_api_key?:                string
	recyclarr_sonarr_api_key?:      string
	prowlarr_api_key?:              string
	bazarr_api_key?:                string
	// Volsync Backup Configuration
	volsync_restic_password?:       string
	volsync_s3_access_key?:         string
	volsync_s3_secret_key?:         string
}

#Config
