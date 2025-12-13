#!/bin/bash
# =============================================================================
# SKRIPT: setup-wordpress.sh
# ZDROJ: wiki.crowncloud.net (LEMP + WordPress)
# UPRAVA: PHP verze 8.3
# =============================================================================

# Zastavit skript při jakékoliv chybě
set -e

# --- 1. PROMENNE (Konfigurace) ---
DB_NAME="wordpress"
DB_USER="admin"
DB_PASS="admin"

# --- 2. UPDATE SYSTEMU & REPOZITARE ---
echo ">>> [1/7] Aktualizace a Repozitare (EPEL + REMI)..."
dnf update -y
dnf install -y epel-release
dnf install -y https://rpms.remirepo.net/enterprise/remi-release-9.rpm
dnf install -y wget unzip tar policycoreutils-python-utils

# --- 3. INSTALACE NGINX & MARIADB ---
echo ">>> [2/7] Instalace Webserveru a Databaze..."
dnf install -y nginx mariadb-server mariadb

# Start sluzeb
systemctl enable --now nginx
systemctl enable --now mariadb

# --- 4. INSTALACE PHP 8.3 ---
echo ">>> [3/7] Instalace PHP 8.3..."
dnf module reset php -y
dnf module enable php:remi-8.3 -y
dnf install -y php php-fpm php-mysqlnd php-curl php-gd php-mbstring php-xml php-xmlrpc php-intl php-zip

# DULEZITE: PHP-FPM na Rocky Linuxu bezi defaultne jako 'apache'.
# Musime to zmenit na 'nginx', jinak vznikne chyba 502/403.
echo " - Konfigurace PHP-FPM (user: nginx)..."
sed -i 's/user = apache/user = nginx/g' /etc/php-fpm.d/www.conf
sed -i 's/group = apache/group = nginx/g' /etc/php-fpm.d/www.conf
systemctl enable --now php-fpm

# --- 5. DATABAZE ---
echo ">>> [4/7] Vytvareni Databaze..."
mysql -u root <<EOF
CREATE DATABASE IF NOT EXISTS ${DB_NAME};
CREATE USER IF NOT EXISTS '${DB_USER}'@'localhost' IDENTIFIED BY '${DB_PASS}';
GRANT ALL PRIVILEGES ON ${DB_NAME}.* TO '${DB_USER}'@'localhost';
FLUSH PRIVILEGES;
EOF

# --- 6. WORDPRESS SOUBORY ---
echo ">>> [5/7] Stahovani WordPress..."
mkdir -p /var/www/html/wordpress
cd /var/www/html/wordpress
# Stahnout, rozbalit a presunout
wget https://wordpress.org/latest.tar.gz
tar -xzf latest.tar.gz --strip-components=1
rm -f latest.tar.gz

# Generovani wp-config.php (S promennymi)
cat > wp-config.php <<EOF
<?php
define( 'DB_NAME', '${DB_NAME}' );
define( 'DB_USER', '${DB_USER}' );
define( 'DB_PASSWORD', '${DB_PASS}' );
define( 'DB_HOST', 'localhost' );
define( 'DB_CHARSET', 'utf8' );
define( 'DB_COLLATE', '' );
\$table_prefix = 'wp_';
define( 'WP_DEBUG', false );
if ( ! defined( 'ABSPATH' ) ) { define( 'ABSPATH', __DIR__ . '/' ); }
require_once ABSPATH . 'wp-settings.php';
EOF

# Nastaveni opravneni
chown -R nginx:nginx /var/www/html/wordpress
chmod -R 755 /var/www/html/wordpress

# --- 7. NGINX VHOST CONFIG ---
echo ">>> [6/7] Konfigurace Nginx..."

# Vypnuti Apache (pokud existuje)
systemctl stop httpd 2>/dev/null || true
systemctl disable httpd 2>/dev/null || true

# Backup default configu
mv /etc/nginx/nginx.conf /etc/nginx/nginx.conf.bak 2>/dev/null || true

# Hlavni nginx.conf (Minimalisticky a funkcni)
cat > /etc/nginx/nginx.conf <<'EOF'
user nginx;
worker_processes auto;
error_log /var/log/nginx/error.log;
pid /run/nginx.pid;
include /usr/share/nginx/modules/*.conf;
events { worker_connections 1024; }
http {
    log_format  main  '$remote_addr - $remote_user [$time_local] "$request" '
                      '$status $body_bytes_sent "$http_referer" '
                      '"$http_user_agent" "$http_x_forwarded_for"';
    access_log  /var/log/nginx/access.log  main;
    sendfile            on;
    tcp_nopush          on;
    tcp_nodelay         on;
    keepalive_timeout   65;
    types_hash_max_size 4096;
    include             /etc/nginx/mime.types;
    default_type        application/octet-stream;
    include /etc/nginx/conf.d/*.conf;
}
EOF

# WordPress Server Block (Smazeme stare a vytvorime novy)
rm -rf /etc/nginx/conf.d/*
cat > /etc/nginx/conf.d/wordpress.conf <<'EOF'
server {
    listen 80;
    server_name _;
    root /var/www/html/wordpress;
    index index.php index.html;

    location / {
        try_files $uri $uri/ /index.php?$args;
    }

    location ~ \.php$ {
        include fastcgi_params;
        fastcgi_pass unix:/run/php-fpm/www.sock;
        fastcgi_index index.php;
        fastcgi_param SCRIPT_FILENAME $document_root$fastcgi_script_name;
    }
}
EOF

# --- 8. FINALIZACE ---
echo ">>> [7/7] Firewall, SELinux a Restart..."
firewall-cmd --permanent --add-service=http
firewall-cmd --permanent --add-service=https
firewall-cmd --reload 2>/dev/null || true

# SELinux povoleni (dulezite pro Nginx->PHP socket)
setsebool -P httpd_can_network_connect 1
setsebool -P httpd_can_network_connect_db 1
chcon -R -t httpd_sys_rw_content_t /var/www/html/wordpress

# Restart vseho
systemctl restart php-fpm
systemctl restart nginx
systemctl restart mariadb

echo "==========================================================="
echo " USPESNE DOKONCENO!"
echo " IP ADRESA: $(curl -s ifconfig.me)"
echo "==========================================================="