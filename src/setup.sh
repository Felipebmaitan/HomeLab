#!/usr/bin/env bash
set -euo pipefail

# Re-exec with sudo if not root
if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
  exec sudo -E bash "$0" "$@"
fi

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
info() { echo -e "${GREEN}[INFO]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
error(){ echo -e "${RED}[ERROR]${NC} $*"; }

cd "$(dirname "$0")"

# Ensure .env exists
if [[ ! -f .env ]]; then
  if [[ -f .env.example ]]; then
    cp .env.example .env
    warn ".env was missing. Copied .env.example -> .env. Review and update secrets/domain."
  else
    error ".env not found and .env.example missing. Create .env and rerun."
    exit 1
  fi
fi

# Load env
set -a
# shellcheck disable=SC1091
source ./.env
set +a

PUID="${PUID:-1000}"
PGID="${PGID:-1000}"
DOMAIN="${DOMAIN:-yourdomain.com}"
ADMIN_EMAIL="${ADMIN_EMAIL:-you@example.com}"

info "PUID=${PUID} PGID=${PGID} DOMAIN=${DOMAIN}"

# Networks
if ! docker network inspect crypto-network >/dev/null 2>&1; then
  info "Creating docker network: crypto-network"
  docker network create crypto-network >/dev/null
else
  info "Network crypto-network already exists"
fi
if ! docker network inspect media-network >/dev/null 2>&1; then
  info "Creating docker network: media-network"
  docker network create media-network >/dev/null
else
  info "Network media-network already exists"
fi

# Required directories (match compose volumes exactly)
info "Creating required directories"
mkdir -p /srv/bitcoin/data /srv/electrs/data
mkdir -p /srv/mempool/backend /srv/mempool/mysql
mkdir -p /srv/jellyfin/config /srv/jellyfin/cache
mkdir -p /srv/sonarr/config /srv/radarr/config /srv/qbittorrent/config /srv/jackett/config
mkdir -p /srv/jackett_blackhole
mkdir -p /srv/media/movies /srv/media/tvshows /srv/media/downloads
mkdir -p ./data/certbot/conf ./data/certbot/www ./data/certbot/work ./data/certbot/logs

# Ownership for media service dirs
info "Setting ownership on media directories to ${PUID}:${PGID}"
chown -R "${PUID}:${PGID}" \
  /srv/jellyfin /srv/sonarr /srv/radarr /srv/qbittorrent /srv/jackett /srv/jackett_blackhole /srv/media || true

# Copy nginx.conf to /srv and patch
NGINX_SRC="./nginx.conf"
NGINX_DST="/srv/nginx.conf"
if [[ ! -f "${NGINX_SRC}" ]]; then
  error "nginx.conf not found at ${NGINX_SRC}"
  exit 1
fi
if [[ -f "${NGINX_DST}" ]]; then
  TS="$(date +%Y%m%d-%H%M%S)"
  cp -f "${NGINX_DST}" "${NGINX_DST}.bak.${TS}"
  info "Backed up existing ${NGINX_DST} to ${NGINX_DST}.bak.${TS}"
fi
cp -f "${NGINX_SRC}" "${NGINX_DST}"
chmod 644 "${NGINX_DST}"

# Patch cert path "_" -> real domain
if grep -q '/etc/letsencrypt/live/_/' "${NGINX_DST}"; then
  if [[ "${DOMAIN}" != "yourdomain.com" ]]; then
    sed -i "s|/etc/letsencrypt/live/_/fullchain.pem|/etc/letsencrypt/live/${DOMAIN}/fullchain.pem|g" "${NGINX_DST}"
    sed -i "s|/etc/letsencrypt/live/_/privkey.pem|/etc/letsencrypt/live/${DOMAIN}/privkey.pem|g" "${NGINX_DST}"
    info "Patched cert paths in /srv/nginx.conf to use domain ${DOMAIN}"
  else
    warn "DOMAIN is 'yourdomain.com'. Update /srv/nginx.conf cert paths after setting DOMAIN."
  fi
fi

# Ensure Jellyfin WebSockets config
if ! grep -q 'map \$http_upgrade \$connection_upgrade' "${NGINX_DST}"; then
  info "Adding map \$http_upgrade \$connection_upgrade to nginx http {}"
  awk '
    BEGIN { inserted=0 }
    /http[[:space:]]*\{/ && !inserted {
      print $0
      print "    map $http_upgrade $connection_upgrade {"
      print "        default upgrade;"
      print "        \"\"      close;"
      print "    }"
      inserted=1
      next
    }
    { print }
  ' "${NGINX_DST}" > "${NGINX_DST}.tmp" && mv "${NGINX_DST}.tmp" "${NGINX_DST}"
fi

if ! grep -q 'proxy_set_header Upgrade \$http_upgrade;' "${NGINX_DST}"; then
  info "Adding Jellyfin WebSocket/streaming headers to /jellyfin/ location"
  awk '
    BEGIN { inblock=0 }
    /^[[:space:]]*location[[:space:]]+\/jellyfin\/[[:space:]]*\{/ { print; inblock=1; next }
    inblock==1 && /^[[:space:]]*\}/ {
      print "            proxy_http_version 1.1;";
      print "            proxy_set_header Upgrade $http_upgrade;";
      print "            proxy_set_header Connection $connection_upgrade;";
      print "            proxy_read_timeout 36000s;";
      print "            proxy_send_timeout 36000s;";
      print "            proxy_buffering off;";
      print $0;
      inblock=0;
      next
    }
    { print }
  ' "${NGINX_DST}" > "${NGINX_DST}.tmp" && mv "${NGINX_DST}.tmp" "${NGINX_DST}"
fi

# Hint for cert generation
if [[ ! -d "./data/certbot/conf/live/${DOMAIN}" ]]; then
  warn "No certs found under ./data/certbot/conf/live/${DOMAIN}."
  echo "  Generate certs before starting nginx:"
  echo "  ./generate-ssl.sh ${DOMAIN} ${ADMIN_EMAIL} false"
fi

info "Setup complete."
echo "Next:"
echo "  1) Review .env (DOMAIN, ADMIN_EMAIL, passwords)."
echo "  2) Generate TLS certs (or ensure existing under ./data/certbot/conf/live/${DOMAIN})."
echo "  3) Start services: ./start-all.sh"