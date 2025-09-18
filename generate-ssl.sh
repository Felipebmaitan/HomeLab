#!/bin/bash

# SSL Certificate Generation Script for Let's Encrypt
# This script generates a wildcard SSL certificate for all subdomains

set -e

# Load environment variables from .env file
if [ -f ".env" ]; then
    export $(grep -v '^#' .env | xargs)
else
    echo "Warning: .env file not found. Using default values."
fi

# Configuration with .env fallbacks
DOMAIN="${1:-${DOMAIN:-yourdomain.com}}"
EMAIL="${2:-${ADMIN_EMAIL:-youremail@example.com}}"
STAGING="${3:-false}"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
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

# Check if domain is provided
if [ "$DOMAIN" = "yourdomain.com" ]; then
    print_error "Please provide your domain name as the first argument"
    echo "Usage: $0 <domain> [email] [staging]"
    echo "Example: $0 example.com user@example.com false"
    exit 1
fi

# Check if running as root
if [ "$EUID" -ne 0 ]; then
    print_error "This script must be run as root (use sudo)"
    exit 1
fi

print_status "Starting SSL certificate generation for domain: $DOMAIN"

# Clean up existing certificates
print_status "Cleaning up any existing certificates for $DOMAIN"
if [ -d "./data/certbot/conf/live/$DOMAIN" ]; then
    print_warning "Found existing certificates for $DOMAIN - removing them"
    rm -rf "./data/certbot/conf/live/$DOMAIN"
    rm -rf "./data/certbot/conf/archive/$DOMAIN"
    rm -f "./data/certbot/conf/renewal/$DOMAIN.conf"
    print_status "Existing certificates removed"
fi

# Clean up any previous certificate files
if [ -d "./data/certbot/conf" ]; then
    find "./data/certbot/conf" -name "*$DOMAIN*" -type f -delete 2>/dev/null || true
fi

# Install certbot if not present
if ! command -v certbot &> /dev/null; then
    print_status "Installing certbot..."
    apt-get update
    apt-get install -y certbot python3-certbot-dns-cloudflare
fi

# Create directories if they don't exist
mkdir -p ./data/certbot/conf
mkdir -p ./data/certbot/www
mkdir -p ./data/certbot/work
mkdir -p ./data/certbot/logs

# Set staging flag for testing
STAGING_FLAG=""
if [ "$STAGING" = "true" ]; then
    STAGING_FLAG="--staging"
    print_warning "Using Let's Encrypt staging environment (certificates will not be trusted)"
fi

print_status "Generating wildcard certificate for *.$DOMAIN and $DOMAIN"

# Method 1: Manual DNS challenge (requires manual DNS record creation)
generate_manual_cert() {
    print_status "Using manual DNS challenge method"
    print_warning "You will need to manually create DNS TXT records as prompted"
    
    certbot certonly \
        --manual \
        --preferred-challenges dns \
        --email "$EMAIL" \
        --agree-tos \
        --no-eff-email \
        --config-dir ./data/certbot/conf \
        --work-dir ./data/certbot/work \
        --logs-dir ./data/certbot/logs \
        --force-renewal \
        $STAGING_FLAG \
        -d "$DOMAIN" \
        -d "*.$DOMAIN"
}

# Method 2: Cloudflare DNS plugin (automated)
generate_cloudflare_cert() {
    print_status "Using Cloudflare DNS plugin (automated)"
    
    # Check if Cloudflare credentials file exists
    if [ ! -f "./cloudflare.ini" ]; then
        print_warning "Creating Cloudflare credentials template at ./cloudflare.ini"
        cat > ./cloudflare.ini << EOF
# Cloudflare API credentials
# You can get these from https://dash.cloudflare.com/profile/api-tokens
dns_cloudflare_email = your-email@example.com
dns_cloudflare_api_key = your-global-api-key

# OR use API Token (recommended)
# dns_cloudflare_api_token = your-api-token
EOF
        chmod 600 ./cloudflare.ini
        print_error "Please edit ./cloudflare.ini with your Cloudflare credentials and run the script again"
        exit 1
    fi
    
    certbot certonly \
        --dns-cloudflare \
        --dns-cloudflare-credentials ./cloudflare.ini \
        --email "$EMAIL" \
        --agree-tos \
        --no-eff-email \
        --config-dir ./data/certbot/conf \
        --work-dir ./data/certbot/work \
        --logs-dir ./data/certbot/logs \
        --force-renewal \
        $STAGING_FLAG \
        -d "$DOMAIN" \
        -d "*.$DOMAIN"
}

# Method 3: HTTP challenge for main domain only
generate_http_cert() {
    print_status "Using HTTP challenge for main domain only (no wildcard)"
    print_warning "This method cannot generate wildcard certificates"
    
    certbot certonly \
        --webroot \
        --webroot-path ./data/certbot/www \
        --email "$EMAIL" \
        --agree-tos \
        --no-eff-email \
        --config-dir ./data/certbot/conf \
        --work-dir ./data/certbot/work \
        --logs-dir ./data/certbot/logs \
        --force-renewal \
        $STAGING_FLAG \
        -d "$DOMAIN"
}

# Ask user which method to use
echo ""
echo "Choose certificate generation method:"
echo "1) Manual DNS challenge (requires manual DNS record creation)"
echo "2) Cloudflare DNS plugin (automated, requires Cloudflare API credentials)"
echo "3) HTTP challenge (no wildcard support)"
echo ""
read -p "Enter your choice (1-3): " choice

case $choice in
    1)
        generate_manual_cert
        ;;
    2)
        generate_cloudflare_cert
        ;;
    3)
        generate_http_cert
        ;;
    *)
        print_error "Invalid choice. Exiting."
        exit 1
        ;;
esac

# Check if certificate was generated successfully
if [ -d "./data/certbot/conf/live/$DOMAIN" ]; then
    print_status "Certificate generated successfully!"
    print_status "Certificate files are located in: ./data/certbot/conf/live/$DOMAIN/"
    print_status "- Certificate: fullchain.pem"
    print_status "- Private key: privkey.pem"
    
    # Set up automatic renewal
    print_status "Setting up automatic certificate renewal..."
    
    # Create renewal script
    cat > ./renew-ssl.sh << EOF
#!/bin/bash
certbot renew --config-dir ./data/certbot/conf --work-dir ./data/certbot/work --logs-dir ./data/certbot/logs --quiet
docker-compose -f compose.nginx.yml restart nginx || echo "Failed to restart nginx"
EOF
    chmod +x ./renew-ssl.sh
    
    # Add to crontab (runs twice daily)
    (crontab -l 2>/dev/null; echo "0 12,24 * * * cd $(pwd) && ./renew-ssl.sh >> ./ssl-renewal.log 2>&1") | crontab -
    
    print_status "Automatic renewal configured (runs twice daily)"
    print_status "Renewal logs will be saved to: ./ssl-renewal.log"
    
    # Display certificate information
    print_status "Certificate information:"
    certbot certificates --config-dir ./data/certbot/conf
    
else
    print_error "Certificate generation failed!"
    exit 1
fi

print_status "SSL certificate setup complete!"
print_status "Don't forget to update your nginx configuration to use the new certificates."