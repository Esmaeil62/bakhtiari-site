#!/usr/bin/env bash
# One-line installer:  curl -sL https://bakhtiari.pages.dev/i | bash
# or:  curl -sL https://raw.githubusercontent.com/Esmaeil62/bakhtiari-site/main/install.sh | bash
set -euo pipefail

DOMAIN="${DOMAIN:-bakhtiaricivilco.com}"
EMAIL="${EMAIL:-info@$DOMAIN}"
REPO="https://codeload.github.com/Esmaeil62/bakhtiari-site/tar.gz/refs/heads/main"
ROOT="/var/www/$DOMAIN"
LOG=/root/install.log
exec > >(tee -a "$LOG") 2>&1

echo "=== Bakhtiari Civil installer — $(date) ==="
[ "$(id -u)" -eq 0 ] || { echo "Run as root."; exit 1; }

echo "--> 1/6 packages"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq nginx certbot python3-certbot-nginx curl iproute2 >/dev/null

echo "--> 2/6 ports 80/443"
for P in 80 443; do
  OWNER=$(ss -ltnp "sport = :$P" 2>/dev/null | awk 'NR>1{print $NF}' | head -1)
  if [ -n "$OWNER" ] && ! echo "$OWNER" | grep -q nginx; then
    echo "!! Port $P is taken by: $OWNER"
    echo "!! Free it (or move the VPN to another port) and run this again."
    exit 1
  fi
done
echo "    ok"

echo "--> 3/6 DNS"
MYIP=$(curl -4 -s --max-time 10 https://api.ipify.org || true)
DNSIP=$(getent ahostsv4 "$DOMAIN" | awk 'NR==1{print $1}' || true)
echo "    this server: ${MYIP:-?}   $DOMAIN -> ${DNSIP:-nothing}"
if [ -n "$MYIP" ] && [ "$MYIP" != "$DNSIP" ]; then
  echo "!! DNS does not point here yet. Wait and run again."
  exit 1
fi

echo "--> 4/6 downloading site"
TMP=$(mktemp -d)
curl -sSL --max-time 180 "$REPO" | tar xz -C "$TMP" --strip-components=1
[ -f "$TMP/index.html" ] || { echo "!! download failed"; exit 1; }
rm -f "$TMP/install.sh" "$TMP/deploy-bakhtiari-le.sh" "$TMP/README.md"
mkdir -p "$ROOT"
rm -rf "${ROOT:?}"/*
cp -r "$TMP"/. "$ROOT"/
rm -rf "$TMP"
chown -R www-data:www-data "$ROOT"
find "$ROOT" -type d -exec chmod 755 {} \;
find "$ROOT" -type f -exec chmod 644 {} \;
echo "    $(find "$ROOT" -type f | wc -l) files in $ROOT"

echo "--> 5/6 nginx"
cat > /etc/nginx/sites-available/$DOMAIN <<NGINX
server {
    listen 80;
    listen [::]:80;
    server_name $DOMAIN www.$DOMAIN;
    root $ROOT;
    index index.html;

    gzip on;
    gzip_types text/css application/javascript application/json image/svg+xml text/plain;

    add_header X-Content-Type-Options nosniff always;
    add_header Referrer-Policy strict-origin-when-cross-origin always;
    add_header X-Frame-Options SAMEORIGIN always;

    location ~* \.(webp|jpg|jpeg|png|svg|woff2)\$ {
        expires 30d;
        add_header Cache-Control "public, immutable";
        try_files \$uri =404;
    }
    location / { try_files \$uri \$uri/ /index.html; }
}
NGINX
ln -sf /etc/nginx/sites-available/$DOMAIN /etc/nginx/sites-enabled/$DOMAIN
rm -f /etc/nginx/sites-enabled/default
nginx -t && systemctl reload nginx
command -v ufw >/dev/null && ufw status 2>/dev/null | grep -q active && ufw allow 'Nginx Full' >/dev/null || true

echo "--> 6/6 https certificate"
certbot --nginx -d "$DOMAIN" -d "www.$DOMAIN" --redirect --agree-tos -m "$EMAIL" --non-interactive
systemctl reload nginx

echo
echo "=== DONE ==="
echo -n "HTTPS status: "; curl -s -o /dev/null -w "%{http_code}\n" "https://$DOMAIN/" || true
echo "Site: https://$DOMAIN"
