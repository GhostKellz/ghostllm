#!/bin/bash

# GhostLLM Proxmox LXC Deployment Helper
# Deploys GhostLLM in a Docker-enabled LXC container

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration
CONTAINER_NAME="ghostllm"
TEMPLATE="debian-12-standard_12.2-1_amd64.tar.zst"
STORAGE="local-lvm"
CORES=2
MEMORY=2048
DISK_SIZE="8G"
BRIDGE="vmbr0"

# Function to print colored output
print_status() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

print_header() {
    echo -e "${BLUE}================================${NC}"
    echo -e "${BLUE} GhostLLM Proxmox LXC Deployer ${NC}"
    echo -e "${BLUE}================================${NC}"
}

# Check if running as root
check_root() {
    if [[ $EUID -ne 0 ]]; then
        print_error "This script must be run as root"
        exit 1
    fi
}

# Get next available VMID
get_next_vmid() {
    local vmid=100
    while pct status $vmid &>/dev/null; do
        ((vmid++))
    done
    echo $vmid
}

# Get IP address from user
get_ip_config() {
    echo -e "${BLUE}Network Configuration${NC}"
    read -p "Enter IP address (e.g., 192.168.1.100/24): " IP_ADDRESS
    read -p "Enter gateway (e.g., 192.168.1.1): " GATEWAY
    read -p "Enter DNS server (default: 8.8.8.8): " DNS_SERVER
    DNS_SERVER=${DNS_SERVER:-8.8.8.8}
}

# Create and configure LXC container
create_container() {
    local vmid=$1
    
    print_status "Creating LXC container with VMID: $vmid"
    
    pct create $vmid /var/lib/vz/template/cache/$TEMPLATE \
        --hostname $CONTAINER_NAME \
        --cores $CORES \
        --memory $MEMORY \
        --rootfs $STORAGE:$DISK_SIZE \
        --net0 name=eth0,bridge=$BRIDGE,firewall=1,ip=$IP_ADDRESS,gw=$GATEWAY \
        --nameserver $DNS_SERVER \
        --ostype debian \
        --unprivileged 1 \
        --features nesting=1,keyctl=1 \
        --start 1
        
    print_status "Container created successfully"
}

# Install Docker in the container
install_docker() {
    local vmid=$1
    
    print_status "Installing Docker using community script..."
    
    # Use the community Docker installation script
    pct exec $vmid -- bash -c "$(curl -fsSL https://raw.githubusercontent.com/community-scripts/ProxmoxVE/main/ct/docker.sh)"
    
    print_status "Docker installation completed"
}

# Deploy GhostLLM
deploy_ghostllm() {
    local vmid=$1
    
    print_status "Deploying GhostLLM..."
    
    # Create app directory
    pct exec $vmid -- mkdir -p /opt/ghostllm
    
    # Copy GhostLLM files (assuming they're in current directory)
    if [[ -f "docker-compose.yml" ]]; then
        pct push $vmid docker-compose.yml /opt/ghostllm/docker-compose.yml
        print_status "Copied docker-compose.yml"
    fi
    
    if [[ -f "Dockerfile" ]]; then
        pct push $vmid Dockerfile /opt/ghostllm/Dockerfile
        print_status "Copied Dockerfile"
    fi
    
    # Copy source code
    if [[ -d "src" ]]; then
        pct exec $vmid -- mkdir -p /opt/ghostllm/src
        for file in src/*; do
            if [[ -f "$file" ]]; then
                pct push $vmid "$file" "/opt/ghostllm/$file"
            fi
        done
        print_status "Copied source files"
    fi
    
    # Copy build files
    for file in build.zig build.zig.zon README.md LICENSE; do
        if [[ -f "$file" ]]; then
            pct push $vmid "$file" "/opt/ghostllm/$file"
        fi
    done
    
    # Create data directory
    pct exec $vmid -- mkdir -p /opt/ghostllm/data
    
    # Build and start GhostLLM
    pct exec $vmid -- bash -c "cd /opt/ghostllm && docker-compose up -d --build"
    
    print_status "GhostLLM deployed and started"
}

# Setup systemd service for auto-start
setup_autostart() {
    local vmid=$1
    
    print_status "Setting up auto-start service..."
    
    # Create systemd service file
    cat > /tmp/ghostllm.service << EOF
[Unit]
Description=GhostLLM Docker Compose
Requires=docker.service
After=docker.service

[Service]
Type=oneshot
RemainAfterExit=yes
WorkingDirectory=/opt/ghostllm
ExecStart=/usr/bin/docker-compose up -d
ExecStop=/usr/bin/docker-compose down
TimeoutStartSec=0

[Install]
WantedBy=multi-user.target
EOF

    pct push $vmid /tmp/ghostllm.service /etc/systemd/system/ghostllm.service
    
    pct exec $vmid -- systemctl daemon-reload
    pct exec $vmid -- systemctl enable ghostllm.service
    
    rm /tmp/ghostllm.service
    
    print_status "Auto-start service configured"
}

# Display completion info
show_completion_info() {
    local vmid=$1
    
    echo
    print_header
    print_status "GhostLLM deployment completed!"
    echo
    echo -e "${BLUE}Container Details:${NC}"
    echo "  VMID: $vmid"
    echo "  IP Address: $IP_ADDRESS"
    echo "  Hostname: $CONTAINER_NAME"
    echo
    echo -e "${BLUE}GhostLLM Access:${NC}"
    echo "  HTTP API: http://${IP_ADDRESS%/*}:8080"
    echo "  Ollama: http://${IP_ADDRESS%/*}:11434"
    echo
    echo -e "${BLUE}Management Commands:${NC}"
    echo "  Enter container: pct enter $vmid"
    echo "  View logs: pct exec $vmid -- docker-compose -f /opt/ghostllm/docker-compose.yml logs"
    echo "  Restart: pct exec $vmid -- docker-compose -f /opt/ghostllm/docker-compose.yml restart"
    echo
}

# Main execution
main() {
    print_header
    
    check_root
    
    print_status "Starting GhostLLM LXC deployment..."
    
    # Get configuration
    get_ip_config
    
    # Get next available VMID
    VMID=$(get_next_vmid)
    print_status "Using VMID: $VMID"
    
    # Create container
    create_container $VMID
    
    # Wait for container to be ready
    sleep 10
    
    # Install Docker
    install_docker $VMID
    
    # Deploy GhostLLM
    deploy_ghostllm $VMID
    
    # Setup auto-start
    setup_autostart $VMID
    
    # Show completion info
    show_completion_info $VMID
}

# Check if script is being sourced or executed
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi