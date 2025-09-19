#!/bin/bash

# Stop All Services Script
# This script stops all Docker containers and optionally removes networks

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

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
    echo -e "${BLUE}[HEADER]${NC} $1"
}

# Parse command line arguments
REMOVE_NETWORKS=false
REMOVE_VOLUMES=false

while [[ $# -gt 0 ]]; do
    case $1 in
        --remove-networks)
            REMOVE_NETWORKS=true
            shift
            ;;
        --remove-volumes)
            REMOVE_VOLUMES=true
            shift
            ;;
        --help|-h)
            echo "Usage: $0 [options]"
            echo "Options:"
            echo "  --remove-networks    Remove Docker networks after stopping services"
            echo "  --remove-volumes     Remove Docker volumes (WARNING: This will delete all data!)"
            echo "  --help, -h           Show this help message"
            exit 0
            ;;
        *)
            print_error "Unknown option: $1"
            echo "Use --help for usage information"
            exit 1
            ;;
    esac

done

print_header "Stopping Docker Services"

# Stacks and standalone services
STACK_FILES=("bitcoin" "mempool")
MEDIA_SERVICES=("qbittorrent" "jackett" "sonarr" "radarr" "jellyfin")
PROXY_SERVICES=("nginx" "certbot")

# Helper to stop a compose file stack
stop_stack() {
    local base=$1
    local compose_file="compose.${base}.yml"

    if [ -f "$compose_file" ]; then
        print_status "Stopping stack: $base..."
        docker compose -f "$compose_file" down
        print_status "Stack $base stopped"
    else
        print_warning "Compose file $compose_file not found, skipping stack $base"
    fi
}

# Stop standalone service
stop_service() {
    local service=$1
    local compose_file="compose.${service}.yml"
    
    if [ -f "$compose_file" ]; then
        print_status "Stopping $service..."
        if docker compose -f "$compose_file" ps -q | xargs docker inspect -f '{{.State.Status}}' 2>/dev/null | grep -q "running"; then
            docker compose -f "$compose_file" down
            print_status "$service stopped"
        else
            print_status "$service was not running"
        fi
    else
        print_warning "Compose file $compose_file not found, skipping $service"
    fi
}

# Stop services in reverse dependency order
print_status "Stopping services in dependency order..."

# Stop proxy first
for service in "${PROXY_SERVICES[@]}"; do
    stop_service "$service"
done

# Stop media services
for service in "${MEDIA_SERVICES[@]}"; do
    stop_service "$service"
done

# Stop stacks (mempool before bitcoin)
stop_stack "mempool"
stop_stack "bitcoin"

# Remove networks if requested
if [ "$REMOVE_NETWORKS" = true ]; then
    print_header "Removing Docker Networks"
    
    # Remove networks (only if no containers are using them)
    for network in "media-network" "crypto-network"; do
        if docker network ls | grep -q "$network"; then
            print_status "Removing $network..."
            if docker network rm "$network" 2>/dev/null; then
                print_status "$network removed"
            else
                print_warning "Could not remove $network (may still be in use)"
            fi
        else
            print_status "$network does not exist"
        fi
    done
fi

# Remove volumes if requested (DANGEROUS!)
if [ "$REMOVE_VOLUMES" = true ]; then
    print_header "⚠️  REMOVING DOCKER VOLUMES (ALL DATA WILL BE LOST!) ⚠️"
    print_warning "This will delete all Bitcoin blockchain data, databases, and configurations!"
    echo ""
    read -p "Are you absolutely sure? Type 'DELETE ALL DATA' to confirm: " confirmation
    
    if [ "$confirmation" = "DELETE ALL DATA" ]; then
        print_status "Removing Docker volumes..."
        
        # Stop any remaining containers first
        docker container prune -f
        
        # Remove volumes
        docker volume ls -q | xargs -r docker volume rm 2>/dev/null || true
        
        print_status "All Docker volumes removed"
        print_warning "All data has been permanently deleted!"
    else
        print_status "Volume removal cancelled"
    fi
fi

# Display final status
print_header "Service Status Summary"
echo ""

RUNNING_CONTAINERS=$(docker ps --format "table {{.Names}}" | grep -E "(bitcoin-core|electrs|mempool|jellyfin|sonarr|radarr|jackett|qbittorrent|nginx|certbot)" | wc -l || echo "0")

if [ "$RUNNING_CONTAINERS" -eq 0 ]; then
    print_status "✓ All services stopped successfully"
else
    print_warning "⚠ Some containers may still be running:"
    docker ps --format "table {{.Names}}\t{{.Status}}" | grep -E "(bitcoin-core|electrs|mempool|jellyfin|sonarr|radarr|jackett|qbittorrent|nginx|certbot)" || true
fi

echo ""
print_status "Networks:"
for network in "media-network" "crypto-network"; do
    if docker network ls | grep -q "$network"; then
        echo "  • $network: exists"
    else
        echo "  • $network: removed"
    fi
done

echo ""
print_status "Docker system status:"
echo "  • Containers: $(docker ps -q | wc -l) running"
echo "  • Images: $(docker images -q | wc -l) total"
echo "  • Volumes: $(docker volume ls -q | wc -l) total"
echo "  • Networks: $(docker network ls -q | wc -l) total"

echo ""
print_header "All services stopped!"
print_status "To start services again, run: ./start-all.sh"
print_status "To completely clean up Docker: docker system prune -a --volumes"
