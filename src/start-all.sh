#!/bin/bash

# Start All Services Script
# This script creates networks and starts all Docker containers in the correct order

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

# Check if .env file exists
if [ ! -f ".env" ]; then
    print_error ".env file not found! Please create it before running this script."
    print_status "You can copy .env.example to .env and edit the values"
    exit 1
fi

print_header "Starting Docker Services Setup"

# Create Docker networks if they don't exist
print_status "Creating Docker networks..."

if ! docker network ls | grep -q "crypto-network"; then
    print_status "Creating crypto-network..."
    docker network create crypto-network
else
    print_status "crypto-network already exists"
fi

if ! docker network ls | grep -q "media-network"; then
    print_status "Creating media-network..."
    docker network create media-network
else
    print_status "media-network already exists"
fi

# Create required directories
print_status "Creating required directories..."
mkdir -p /srv/bitcoin/data
mkdir -p /srv/electrs/data
mkdir -p /srv/mempool/backend
mkdir -p /srv/mempool/mysql
mkdir -p /srv/jellyfin/config
mkdir -p /srv/jellyfin/cache
mkdir -p /srv/sonarr/config
mkdir -p /srv/radarr/config
mkdir -p /srv/qbittorrent/config
mkdir -p /srv/jackett/config
mkdir -p /srv/jackett_blackhole
mkdir -p /srv/media/movies
mkdir -p /srv/media/tvshows
mkdir -p /srv/media/downloads
mkdir -p ./data/certbot/conf
mkdir -p ./data/certbot/www

# Set proper permissions
print_status "Setting directory permissions..."
chown -R 1000:1000 /srv/jellyfin /srv/sonarr /srv/radarr /srv/qbittorrent /srv/jackett /srv/media

# Define containers for status reporting and standalone stacks
CRYPTO_CONTAINERS=("bitcoin-core" "electrs" "mempool-db" "mempool-backend" "mempool-frontend")
MEDIA_SERVICES=("qbittorrent" "jackett" "sonarr" "radarr" "jellyfin")
PROXY_SERVICES=("nginx" "certbot")

# Function to start a single-service compose file (media/proxy)
start_service() {
    local service=$1
    local compose_file="compose.${service}.yml"
    
    if [ -f "$compose_file" ]; then
        print_status "Starting $service..."
        docker compose -f "$compose_file" --env-file .env up -d
        
        # Wait a bit for the service to start
        sleep 2
        
        # Check if service is running
        if docker compose -f "$compose_file" --env-file .env ps | grep -q "Up"; then
            print_status "$service started successfully"
        else
            print_warning "$service may not have started correctly"
        fi
    else
        print_error "Compose file $compose_file not found!"
    fi
}

# Function to start a grouped compose file (e.g., bitcoin stack, mempool stack)
start_compose_file() {
    local base=$1
    local compose_file="compose.${base}.yml"

    if [ -f "$compose_file" ]; then
        print_status "Starting compose stack: $base..."
        docker compose -f "$compose_file" --env-file .env up -d
        sleep 2
    else
        print_error "Compose file $compose_file not found!"
    fi
}

# Function to wait for service health
wait_for_service() {
    local service=$1
    local max_attempts=30
    local attempt=1
    
    print_status "Waiting for $service to be healthy..."
    
    while [ $attempt -le $max_attempts ]; do
        if docker ps --format "table {{.Names}}\t{{.Status}}" | grep "$service" | grep -q "healthy"; then
            print_status "$service is ready"
            return 0
        fi
        
        echo -n "."
        sleep 2
        attempt=$((attempt + 1))
    done
    
    print_warning "$service health check timed out"
    return 1
}

# Start crypto stacks (grouped)
print_header "Starting Crypto Services"
start_compose_file "bitcoin"
wait_for_service "bitcoin-core"
start_compose_file "mempool"
wait_for_service "mempool-db"

# Start media services
print_header "Starting Media Services"
for service in "${MEDIA_SERVICES[@]}"; do
    start_service "$service"
done

# Start proxy services
print_header "Starting Proxy Services"
for service in "${PROXY_SERVICES[@]}"; do
    start_service "$service"
done

# Display status
print_header "Service Status Summary"
echo ""
print_status "Crypto Services:"
for service in "${CRYPTO_CONTAINERS[@]}"; do
    if docker ps --format "table {{.Names}}\t{{.Status}}" | grep -q "$service"; then
        status=$(docker ps --format "table {{.Names}}\t{{.Status}}" | grep "$service" | awk '{print $2}')
        echo "  ✓ $service: $status"
    else
        echo "  ✗ $service: Not running"
    fi
done

echo ""
print_status "Media Services:"
for service in "${MEDIA_SERVICES[@]}"; do
    if docker ps --format "table {{.Names}}\t{{.Status}}" | grep -q "$service"; then
        status=$(docker ps --format "table {{.Names}}\t{{.Status}}" | grep "$service" | awk '{print $2}')
        echo "  ✓ $service: $status"
    else
        echo "  ✗ $service: Not running"
    fi
done

echo ""
print_status "Proxy Services:"
for service in "${PROXY_SERVICES[@]}"; do
    if docker ps --format "table {{.Names}}\t{{.Status}}" | grep -q "nginx\|certbot"; then
        status=$(docker ps --format "table {{.Names}}\t{{.Status}}" | grep -E "nginx|certbot" | awk '{print $2}')
        echo "  ✓ $service: $status"
    else
        echo "  ✗ $service: Not running"
    fi
done

echo ""
print_header "Access URLs"
source .env 2>/dev/null || true

echo "Local Access:"
echo "  • Jellyfin: http://localhost:${JELLYFIN_PORT:-8096}"
echo "  • Sonarr: http://localhost:${SONARR_PORT:-8989}"
echo "  • Radarr: http://localhost:${RADARR_PORT:-7878}"
echo "  • qBittorrent: http://localhost:${QBITTORRENT_WEBUI_PORT:-8080}"
echo "  • Jackett: http://localhost:${JACKETT_PORT:-9117}"
echo "  • Mempool: http://localhost:${MEMPOOL_FRONTEND_PORT:-8090}"
echo "  • Bitcoin Core RPC: http://localhost:${BITCOIN_RPC_PORT:-8332}"
echo "  • Electrs: tcp://localhost:${ELECTRS_PORT:-50001}"

if [ -n "$DOMAIN" ] && [ "$DOMAIN" != "yourdomain.com" ]; then
    echo ""
    echo "External Access (when reverse proxy is configured):"
    echo "  • Jellyfin: ${JELLYFIN_EXTERNAL_URL:-https://jellyfin.$DOMAIN}"
    echo "  • Sonarr: ${SONARR_EXTERNAL_URL:-https://$DOMAIN/sonarr}"
    echo "  • Radarr: ${RADARR_EXTERNAL_URL:-https://$DOMAIN/radarr}"
    echo "  • qBittorrent: ${QBITTORRENT_EXTERNAL_URL:-https://$DOMAIN/qbittorrent}"
    echo "  • Jackett: ${JACKETT_EXTERNAL_URL:-https://$DOMAIN/jackett}"
    echo "  • Mempool: ${MEMPOOL_EXTERNAL_URL:-https://$DOMAIN/mempool}"
fi

print_header "All services started!"
print_status "Check the logs with: docker compose -f compose.<service>.yml logs -f"
print_status "Stop all services with: ./stop-all.sh"
