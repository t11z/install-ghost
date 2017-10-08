#!/bin/bash

GHOST_URL=$(curl -s https://api.github.com/repos/TryGhost/Ghost/releases/latest | grep browser_download_url | cut -d '"' -f 4)
GHOST_VERSION=$(curl -s https://api.github.com/repos/TryGhost/Ghost/releases/latest | grep -m 1 \"name\" | cut -d '"' -f 4)

setup() {
  echo -n "Which Domain name will your Ghost blog be listening on (e.g.: blog.mydomain.com)? "; read BLOG_DOMAIN
  echo -n "Specify base directory for Ghost installation (default: /opt/ghost/): "; read BASE_DIR
  echo -n "Install and configure NGINX web server? (y|N|i|c) (i=install only, c=configure only): "; read INSTALL_NGINX
  if [ "$INSTALL_NGINX" = "y" ]; then echo -n "Install acmetool for automatic Let's Encrypt certificate generation? (y|N): "; read INSTALL_ACMETOOL; fi
  echo -n "Add separate user and create systemd service for Ghost? (y|N): "; read CONFIGURE_SYSTEMD
}

install_acmetool() {
  add-apt-repository -y ppa:hlandau/rhea
  apt -y update
  apt -y install acmetool
}

configure_acmetool() {
  echo "Configuring acmetool..."
  echo " ###################### "
  echo " ### IMPORTANT NOTE ### "
  echo " ################################ "
  echo " # Choose PROXY MODE in Step 2! # "
  echo " ################################ "
  acmetool quickstart
  read -r -d '' INCLUDE_ACMETOOL <<'EOF'
    location /.well-known/acme-challenge/ {
      proxy_pass http://127.0.0.1:402;
    }
EOF
}

install_nginx() {
  apt -y install nginx
}

configure_nginx() {
if [ "$INSTALL_ACMETOOL" = "y" ]; then
  read -r -d '' INCLUDE_NGINX_HTTP <<EOF
  location / {
    return 301 https://\$host\$request_uri;
  }

EOF
  read -r -d '' INCLUDE_NGINX_HTTPS <<EOF
server {
  listen 443 ssl http2;
  listen [::]:443 ssl http2;
  server_name .$BLOG_DOMAIN;

  ssl_certificate /var/lib/acme/live/$BLOG_DOMAIN/fullchain;
  ssl_certificate_key /var/lib/acme/live/$BLOG_DOMAIN/privkey;

  ssl_session_cache shared:SSL:50m;
  ssl_session_timeout 1d;
  ssl_session_tickets off;

  ssl_dhparam /etc/ssl/dhparam2048.pem;

  ssl_prefer_server_ciphers on;
  ssl_protocols TLSv1 TLSv1.1 TLSv1.2;
  ssl_ciphers 'ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305:ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:DHE-RSA-AES128-GCM-SHA256:DHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-AES128-SHA256:ECDHE-RSA-AES128-SHA256:ECDHE-ECDSA-AES128-SHA:ECDHE-RSA-AES256-SHA384:ECDHE-RSA-AES128-SHA:ECDHE-ECDSA-AES256-SHA384:ECDHE-ECDSA-AES256-SHA:ECDHE-RSA-AES256-SHA:DHE-RSA-AES128-SHA256:DHE-RSA-AES128-SHA:DHE-RSA-AES256-SHA256:DHE-RSA-AES256-SHA:ECDHE-ECDSA-DES-CBC3-SHA:ECDHE-RSA-DES-CBC3-SHA:EDH-RSA-DES-CBC3-SHA:AES128-GCM-SHA256:AES256-GCM-SHA384:AES128-SHA256:AES256-SHA256:AES128-SHA:AES256-SHA:DES-CBC3-SHA:!DSS';

  resolver 8.8.8.8 8.8.4.4;
  ssl_stapling on;
  ssl_stapling_verify on;
  ssl_trusted_certificate /var/lib/acme/live/$BLOG_DOMAIN/cert;

  add_header Strict-Transport-Security "max-age=31536000; includeSubdomains; preload";

  location / {
  proxy_set_header HOST \$host;
  proxy_set_header X-Forwarded-Proto \$scheme;
  proxy_set_header X-Real-IP \$remote_addr;
  proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    proxy_pass http://127.0.0.1:2368;
  }
}

EOF
  if [ ! -f "/etc/ssl/dhparam2048.pem 2048" ]; then
    openssl dhparam -outform PEM -out dhparam2048.pem 2048
  fi
else
  read -r -d '' INCLUDE_NGINX_HTTP <<EOF
  location / {
  proxy_set_header HOST \$host;
  proxy_set_header X-Forwarded-Proto \$scheme;
  proxy_set_header X-Real-IP \$remote_addr;
  proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    proxy_pass http://127.0.0.1:2368;
  }

EOF
fi

  cat > /etc/nginx/sites-available/ghost <<EOF
server {
  listen 80;
  server_name $BLOG_DOMAIN;

  $INCLUDE_NGINX_HTTP
  $INCLUDE_ACMETOOL
}

$INCLUDE_NGINX_HTTPS
EOF
  sudo ln -s /etc/nginx/sites-available/ghost /etc/nginx/sites-enabled/ghost
  systemctl enable nginx
  systemctl restart nginx

  if [ "$INSTALL_ACMETOOL" = "y" ]; then
    acmetool want $BLOG_DOMAIN
  fi
}

configure_systemd() {
  cat > /etc/systemd/system/ghost.service <<'EOF'
[Unit]
Description=Ghost
After=network.target

[Service]
Type=simple

WorkingDirectory=/opt/ghost/latest
User=ghost
Group=ghost

ExecStart=/usr/bin/npm start --production
ExecStop=/usr/bin/npm stop --production
Restart=always
SyslogIdentifier=Ghost

[Install]
WantedBy=multi-user.target
EOF
  systemctl enable ghost.service
}

configure_ghostuser() {
  id ghost &> /dev/null
  if [ "$?" = "1" ]; then
    adduser --system --group --no-create-home --disabled-password --gecos 'Ghost application' ghost
    chown -R ghost:ghost $BASE_DIR
  else
    echo "User ghost already exists. Skipping."
  fi
}

install_ghost() {
  echo "Checking dependencies..."

  echo -n "nodejs... "
  dpkg -s nodejs &> /dev/null
  if [ $? = 1 ]; then
    echo "not installed. Installing now."
    apt -y install nodejs npm
  else
    echo "installed."
  fi

  ln -sf /usr/bin/nodejs /usr/bin/node

  echo -n "unzip... "
  dpkg -s unzip &> /dev/null
  if [ $? = 1 ]; then
    echo "not installed. Installing now."
    apt -y install unzip
  else
    echo "installed."
  fi

  echo "npm-install-que... "
  npm list -g npm-install-que &> /dev/null
  if [ $? = 1 ]; then
    echo "not installed. Installing now."
    npm install -g npm-install-que
  else
    echo "installed."
  fi

  echo "knex-migrator... "
  npm list -g knex-migrator &> /dev/null
  if [ $? = 1 ]; then
    echo "not installed. Installing now."
    npm install -g knex-migrator
  else
    echo "installed."
  fi

  echo "Downloading latest Ghost release..."
  if [ ! -d $BASE_DIR/$GHOST_VERSION ]; then
    echo "Creating $BASE_DIR/$GHOST_VERSION..."
    mkdir -p $BASE_DIR/$GHOST_VERSION
  fi
  wget -O $BASE_DIR/ghost_latest.zip $GHOST_URL
  ln -sf $BASE_DIR/$GHOST_VERSION $BASE_DIR/latest
  cd $BASE_DIR/$GHOST_VERSION

  unzip $BASE_DIR/ghost_latest.zip
  export NODE_ENV=production
  npm install sqlite3
  knex-migrator init

  npm-install-que

  rm -f $BASE_DIR/ghost_latest.zip
}

configure_ghost() {
  cat > $BASE_DIR/$GHOST_VERSION/core/server/config/env/config.production.json <<EOF
{
    "url": "http://$BLOG_DOMAIN",
    "database": {
        "client": "sqlite3",
        "connection": {
            "filename": "content/data/ghost.db"
        },
        "debug": false
    },
    "paths": {
        "contentPath": "content/"
    },
    "privacy": {
        "useRpcPing": false,
        "useUpdateCheck": true
    },
    "useMinFiles": false,
    "caching": {
        "theme": {
            "maxAge": 0
        },
        "admin": {
            "maxAge": 0
        }
    }
}
EOF
}

setup

if [ "$BASE_DIR" = "" ]; then
  BASE_DIR=/opt/ghost
fi

case $INSTALL_NGINX in
  y)
    install_nginx
    if [ "$INSTALL_ACMETOOL" = "y" ]; then
      install_acmetool
      configure_acmetool
    fi
    configure_nginx
  ;;
  i)
    install_nginx
  ;;
  c)
    configure_nginx
  ;;
esac

install_ghost
configure_ghost

if [ "$CONFIGURE_SYSTEMD" = "y" ]; then
  configure_ghostuser
  configure_systemd
fi

echo "All installation steps complete!"
