#!/usr/bin/env bash
# Bakhtiari Civil website installer — nginx + Let's Encrypt (Ubuntu/Debian)
# Usage:  sudo bash deploy-bakhtiari-le.sh bakhtiaricivilco.com bakhtiari-website-v2.zip you@email.com
set -euo pipefail

DOMAIN="${1:?domain required, e.g. bakhtiaricivilco.com}"
ZIP="${2:?path to bakhtiari-website-v2.zip required}"
EMAIL="${3:-info@$DOMAIN}"
ROOT="/var/www/$DOMAIN"

[ "$(id -u)" -eq 0 ] || { echo "Run as root (sudo)."; exit 1; }
[ -f "$ZIP" ] || { echo "Zip not found: $ZIP"; exit 1; }

echo "==> 1/6 Checking that ports 80 and 443 are free"
apt-get update -qq && apt-get install -y -qq iproute2 >/dev/null
for P in 80 443; do
  OWNER=$(ss -ltnp "sport = :$P" 2>/dev/null | awk 'NR>1{print $NF}' | head -1)
  if [ -n "$OWNER" ] && ! echo "$OWNER" | grep -q nginx; then
    echo "!! Port $P is already used by: $OWNER"
    echo "!! (On a VPN server, Xray/V2Ray usually holds 443.) Use another server, or move the VPN to a different port first."
    exit 1
  fi
done

echo "==> 2/6 Checking DNS points to this server"
MYIP=$(curl -4 -s https://api.ipify.org || true)
DNSIP=$(getent ahostsv4 "$DOMAIN" | awk 'NR==1{print $1}' || true)
echo "    server IP: ${MYIP:-unknown}   $DOMAIN resolves to: ${DNSIP:-nothing yet}"
if [ -n "$MYIP" ] && [ "$MYIP" != "$DNSIP" ]; then
  echo "!! DNS does not point here yet. Wait 5–30 minutes after setting the A record, then run again."
  exit 1
fi

echo "==> 3/6 Installing nginx, certbot, unzip"
apt-get install -y -qq nginx certbot python3-certbot-nginx unzip >/dev/null

echo "==> 4/6 Copying site files to $ROOT"
mkdir -p "$ROOT"
TMP=$(mktemp -d); unzip -q -o "$ZIP" -d "$TMP"
rsync -a --delete "$TMP"/ "$ROOT"/ 2>/dev/null || { rm -rf "$ROOT"/*; cp -r "$TMP"/. "$ROOT"/; }
rm -rf "$TMP"
chown -R www-data:www-data "$ROOT"; find "$ROOT" -type d -exec chmod 755 {} \; ; find "$ROOT" -type f -exec chmod 644 {} \;

echo "==> 5/6 Writing nginx config"
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

    location ~* \.(webp|jpg|jpeg|png|svg|woff2)\$ { expires 30d; add_header Cache-Control "public, immutable"; try_files \$uri =404; }
    location / { try_files \$uri \$uri/ /index.html; }
}
NGINX
ln -sf /etc/nginx/sites-available/$DOMAIN /etc/nginx/sites-enabled/$DOMAIN
rm -f /etc/nginx/sites-enabled/default
nginx -t && systemctl reload nginx
if command -v ufw >/dev/null && ufw status | grep -q active; then ufw allow 'Nginx Full' >/dev/null; fi

echo "==> 6/6 Getting the Let's Encrypt certificate (auto-renews)"
certbot --nginx -d "$DOMAIN" -d "www.$DOMAIN" --redirect --agree-tos -m "$EMAIL" --non-interactive
# canonical host: www -> bare domain
sed -i "0,/server_name $DOMAIN www.$DOMAIN;/s//server_name $DOMAIN www.$DOMAIN;\n    if (\$host = www.$DOMAIN) { return 301 https:\/\/$DOMAIN\$request_uri; }/" /etc/nginx/sites-available/$DOMAIN
nginx -t && systemctl reload nginx

echo
echo "Done:  https://$DOMAIN"
curl -s -o /dev/null -w "    HTTPS check: %{http_code}\n" "https://$DOMAIN/" || true
