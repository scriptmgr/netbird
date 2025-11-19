#!/bin/sh
# POSIX-compliant installer/updater for a self-hosted NetBird stack
# Components: ZITADEL (IdP), NetBird management, dashboard, signal, coturn (TURN)
# Repo reference: https://github.com/scriptmgr/netbird
# Requirements satisfied by this script: Docker Engine + Compose plugin from official Docker repos (no docker.io pkg)
# Reverse proxy: publish external :64453 and forward to localhost backends printed at the end
# Admin user: 'administrator' with random password (created or reset). Password stored at /opt/netbird/secrets/admin_password

set -eu

#######################################
# Helpers
#######################################
say() { printf '%s\n' "$*"; }
die() {
	say "ERROR: $*" >&2
	exit 1
}
need_cmd() { command -v "$1" >/dev/null 2>&1 || die "missing required command: $1"; }
as_root() { [ "$(id -u)" -eq 0 ] || die "please run as root (sudo sh ./install.sh)"; }

randpass() {
	# 24-char base64-ish without slashes/plus for convenience
	if command -v openssl >/dev/null 2>&1; then
		openssl rand -base64 32 | tr -d '\n' | tr -d '/+' | cut -c1-24
	else
		# fallback
		dd if=/dev/urandom bs=48 count=1 2>/dev/null | LC_ALL=C tr -dc 'A-Za-z0-9' | cut -c1-24
	fi
}

#######################################
# Config defaults (override via env before running)
#######################################
: "${NB_ROOT:=/opt/netbird}"                   # root of your NetBird self-hosted stack
: "${NB_DOMAIN:=vpn2me.us}"                    # external domain for your reverse proxy (e.g., vpn.example.com)
: "${NB_ORG:=netbird}"                         # org slug used in ZITADEL login name suffix
: "${NB_EXTERNAL_PORT:=64453}"                 # external port exposed by your reverse proxy
: "${NB_EMAIL_SMTP_HOST:=127.0.0.1}"           # host's MTA
: "${NB_EMAIL_SMTP_PORT:=25}"                  # host's MTA port
: "${NB_EMAIL_FROM_USER:=no-reply@$NB_DOMAIN}" # from address for transactional emails
: "${NB_TIMEZONE:=America/New_York}"           # TZ for containers
: "${NB_DOCKER_NETWORK:=netbird}"              # docker network name for the stack
: "${NB_EMAIL_FROM_NAME:=CasjaysDev NetBird}"  # smtp email "from" name
# Derived
NB_ETC="$NB_ROOT/etc"
NB_DATA="$NB_ROOT/data"
NB_SECRETS="$NB_ROOT/secrets"
NB_COMPOSE="$NB_ROOT/compose"
NB_STATE="$NB_ROOT/state"
NB_LOG="$NB_ROOT/log"

ZITADEL_DATA="$NB_DATA/zitadel"
ZITA_DB_DATA="$NB_DATA/postgres"
TURN_DATA="$NB_DATA/turn"
MGMT_DATA="$NB_DATA/management" # includes sqlite store if used
SIGNAL_DATA="$NB_DATA/signal"
DASH_DATA="$NB_DATA/dashboard"

ADMIN_USER_LOCAL="administrator"
ADMIN_PASS_FILE="$NB_SECRETS/admin_password"
MASTER_KEY_FILE="$NB_SECRETS/zitadel_master_key"
ZITADEL_ENV_FILE="$NB_ETC/zitadel.env"
NETBIRD_ENV_FILE="$NB_ETC/netbird.env"
MGMT_JSON_FILE="$NB_ETC/management.json"
DC_FILE="$NB_COMPOSE/docker-compose.yml"

# container names for docker compose
ZITADEL_SVC="zitadel"
ZITA_DB_SVC="zitadel-db"
TURN_SVC="coturn"
MGMT_SVC="management"
DASH_SVC="dashboard"
SIG_SVC="signal"

#######################################
# Pre-flight
#######################################
as_root
need_cmd awk
need_cmd sed
need_cmd grep
need_cmd printf
need_cmd uname

mkdir -p "$NB_ETC" "$NB_DATA" "$NB_SECRETS" "$NB_COMPOSE" "$NB_STATE" "$NB_LOG" "$ZITADEL_DATA" "$ZITA_DB_DATA" "$TURN_DATA" "$MGMT_DATA" "$SIGNAL_DATA" "$DASH_DATA"

# set sane perms on secrets
chmod 700 "$NB_SECRETS"

#######################################
# Install/Upgrade Docker Engine (official repos)
#######################################
install_docker() {
	if command -v docker >/dev/null 2>&1; then
		say "Docker already present. Ensuring Compose plugin is available..."
	fi

	OS="$(uname -s)"
	case "$OS" in
	Linux)
		# detect distro
		if [ -f /etc/os-release ]; then
			. /etc/os-release
		else
			ID=unknown
		fi

		case "$ID" in
		ubuntu | debian | raspbian)
			need_cmd apt-get
			# remove distro docker.io if present
			if dpkg -l | grep -q '^ii\s\+docker\.io'; then
				say "Removing docker.io package to avoid conflicts..."
				apt-get remove -y docker.io || true
			fi
			apt-get update -y
			need_cmd gpg
			install -m 0755 -d /etc/apt/keyrings
			if [ ! -f /etc/apt/keyrings/docker.gpg ]; then
				curl -fsSL https://download.docker.com/linux/"$ID"/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
				chmod a+r /etc/apt/keyrings/docker.gpg
			fi
			echo \
				"deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/$ID \
$(
					. /etc/os-release
					echo "$VERSION_CODENAME"
				) stable" >/etc/apt/sources.list.d/docker.list
			apt-get update -y
			apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
			;;
		fedora)
			need_cmd dnf
			dnf -y install dnf-plugins-core
			dnf config-manager --add-repo https://download.docker.com/linux/fedora/docker-ce.repo
			dnf -y install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
			systemctl enable --now docker
			;;
		centos | rhel | rocky | almalinux | ol)
			PM=dnf
			command -v yum >/dev/null 2>&1 && PM=yum
			$PM -y install yum-utils
			$PM config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo
			$PM -y install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
			systemctl enable --now docker
			;;
		opensuse* | sles)
			need_cmd zypper
			zypper refresh
			zypper -n install docker docker-compose
			systemctl enable --now docker
			;;
		arch | manjaro | endeavouros | arcolinux)
			need_cmd pacman
			pacman -Sy --noconfirm docker docker-compose
			systemctl enable --now docker
			;;
		*)
			say "Unknown distro '$ID'. Attempting to use existing Docker if available."
			;;
		esac
		;;
	*)
		die "Unsupported OS: $OS (Linux required for server components)"
		;;
	esac

	command -v docker >/dev/null 2>&1 || die "Docker not installed"
	# prefer plugin: docker compose
	docker compose version >/dev/null 2>&1 || die "Docker Compose plugin not found (docker compose)."
	systemctl is-active docker >/dev/null 2>&1 || systemctl start docker || true
}

#######################################
# Generate secrets and env
#######################################
ensure_secret() {
	file="$1"
	if [ ! -s "$file" ]; then
		umask 077
		printf '%s' "$(randpass)" >"$file"
		say "Generated secret: $file"
	fi
}

# Admin password
ensure_admin_password() {
	if [ ! -s "$ADMIN_PASS_FILE" ]; then
		umask 077
		printf '%s\n' "$(randpass)" >"$ADMIN_PASS_FILE"
		say "Generated admin password at $ADMIN_PASS_FILE"
	fi
}

# ZITADEL master key (required)
ensure_master_key() {
	if [ ! -s "$MASTER_KEY_FILE" ]; then
		umask 077
		# 32 chars
		printf '%s\n' "$(randpass)$(randpass)" | cut -c1-32 >"$MASTER_KEY_FILE"
		say "Generated ZITADEL master key at $MASTER_KEY_FILE"
	fi
}

#######################################
# Compose files and configs
#######################################
write_zitadel_env() {
	cat >"$ZITADEL_ENV_FILE" <<EOF
# Autogenerated by install.sh
TZ="$NB_TIMEZONE"

# Postgres DB credentials (local-only)
POSTGRES_USER=postgres
POSTGRES_PASSWORD=$(randpass)
POSTGRES_DB=zitadel

# ZITADEL first instance bootstrap (admin user & org)
ZITADEL_FIRSTINSTANCE_ORG_NAME="$NB_ORG"
ZITADEL_FIRSTINSTANCE_ORG_HUMAN_USERNAME="$ADMIN_USER_LOCAL"
ZITADEL_FIRSTINSTANCE_ORG_HUMAN_PASSWORD="$(cat "$ADMIN_PASS_FILE")"
ZITADEL_FIRSTINSTANCE_ORG_HUMAN_EMAIL="admin@$NB_DOMAIN"
ZITADEL_EXTERNALDOMAIN="$NB_DOMAIN"
ZITADEL_EXTERNALSECURE=true

# SMTP (host MTA)
ZITADEL_NOTIFICATIONS_SMTPTLS=false
ZITADEL_NOTIFICATIONS_SMTP_FROM="$NB_EMAIL_FROM_USER"
ZITADEL_NOTIFICATIONS_SMTP_PORT="$NB_EMAIL_SMTP_PORT"
ZITADEL_NOTIFICATIONS_SMTP_HOST="$NB_EMAIL_SMTP_HOST"
ZITADEL_NOTIFICATIONS_SMTPSENDERNAME="$NB_EMAIL_FROM_NAME"
EOF
}

write_netbird_env() {
	# OIDC endpoints are derived from ZITADEL external domain
	Z_ISSUER="https://$NB_DOMAIN"
	cat >"$NETBIRD_ENV_FILE" <<EOF
# Autogenerated by install.sh
TZ="$NB_TIMEZONE"

# OIDC (Zitadel)
NETBIRD_AUTH_OIDC_ISSUER=$Z_ISSUER
NETBIRD_AUTH_OIDC_CONFIG_URL=$Z_ISSUER/.well-known/openid-configuration
# These will be filled after first start of management (client registration) if using Zitadel automation.
# You can pre-create a confidential app in Zitadel and set:
# NETBIRD_AUTH_CLIENT_ID=
# NETBIRD_AUTH_CLIENT_SECRET=

# E-mail (host MTA)
NETBIRD_EMAIL_SMTP_HOST="$NB_EMAIL_SMTP_HOST"
NETBIRD_EMAIL_SMTP_PORT="$NB_EMAIL_SMTP_PORT"
NETBIRD_EMAIL_FROM="$NB_EMAIL_FROM_USER"
EOF
}

write_management_json() {
	# Minimal OIDC wiring; for advanced cases, customize later.
	Z_ISSUER="https://$NB_DOMAIN"
	cat >"$MGMT_JSON_FILE" <<'JSON'
{
  "HttpConfig": {
    "IdpSignKeyRefreshEnabled": true,
    "OIDCConfigEndpoint": "__OIDC_CONFIG__",
    "AuthIssuer": "__ISSUER__",
    "AuthAudience": "netbird",
    "AuthKeysLocation": "__ISSUER__/keys"
  },
  "PKCEAuthorizationFlow": {
    "ProviderConfig": {
      "Audience": "netbird",
      "ClientID": "__CLIENT_ID__",
      "ClientSecret": "__CLIENT_SECRET__",
      "AuthorizationEndpoint": "__ISSUER__/oauth/v2/authorize",
      "TokenEndpoint": "__ISSUER__/oauth/v2/token",
      "Scope": "openid email profile",
      "RedirectURLs": [
        "http://localhost:53000"
      ],
      "UseIDToken": true
    }
  }
}
JSON
	# perform basic substitutions with placeholders; user may refine later
	sed -i \
		-e "s#__OIDC_CONFIG__#${Z_ISSUER}/.well-known/openid-configuration#g" \
		-e "s#__ISSUER__#${Z_ISSUER}#g" \
		-e "s#__CLIENT_ID__##g" \
		-e "s#__CLIENT_SECRET__##g" \
		"$MGMT_JSON_FILE"
}

write_compose() {
	cat >"$DC_FILE" <<EOF
# Autogenerated by install.sh — NetBird self-hosted stack
name: netbird
services:

  $ZITA_DB_SVC:
    image: docker.io/postgres:16-alpine
    restart: unless-stopped
    environment:
      - POSTGRES_USER=\${POSTGRES_USER}
      - POSTGRES_PASSWORD=\${POSTGRES_PASSWORD}
      - POSTGRES_DB=\${POSTGRES_DB}
    volumes:
      - $ZITA_DB_DATA:/var/lib/postgresql/data
    networks: [$NB_DOCKER_NETWORK]

  $ZITADEL_SVC:
    image: ghcr.io/zitadel/zitadel:v2.64.1
    depends_on: [$ZITA_DB_SVC]
    restart: unless-stopped
    environment:
      - TZ=\${TZ}
    command: >
      start-from-setup
      --masterkeyFile /run/secrets/masterkey
      --config /zitadel-secrets.yaml
      --externalDomain \${ZITADEL_EXTERNALDOMAIN}
      --externalSecure \${ZITADEL_EXTERNALSECURE}
    secrets:
      - masterkey
      - zitadel-config
    volumes:
      - $ZITADEL_DATA:/zitadel
    networks: [$NB_DOCKER_NETWORK]
    # internal: exposed to reverse proxy only; do not publish to host

  $TURN_SVC:
    image: docker.io/coturn/coturn:latest
    restart: unless-stopped
    command:
      - -n
      - --log-file=stdout
      - --user=netbird:netbird
      - --realm=$NB_DOMAIN
      - --use-auth-secret
      - --static-auth-secret=$(randpass)
      - --no-cli
      - --listening-port=3478
      - --min-port=49152
      - --max-port=49252
    networks: [$NB_DOCKER_NETWORK]
    volumes:
      - $TURN_DATA:/var/lib/coturn

  $MGMT_SVC:
    image: docker.io/netbirdio/management:latest
    restart: unless-stopped
    environment:
      - TZ=\${TZ}
      - NB_DATA_DIR=/var/lib/netbird
      - NB_MANAGEMENT_HTTP_PORT=8080
      - NB_MANAGEMENT_GRPC_PORT=4433
      - NB_MANAGEMENT_SINGLE_ACCOUNT_MODE=true
      - NB_MANAGEMENT_IDP=oidc
      - NB_MANAGEMENT_IDP_MGMT_JSON=/etc/netbird/management.json
      - NB_EMAIL_SMTP_HOST=\${NETBIRD_EMAIL_SMTP_HOST}
      - NB_EMAIL_SMTP_PORT=\${NETBIRD_EMAIL_SMTP_PORT}
      - NB_EMAIL_SENDER=\${NETBIRD_EMAIL_FROM}
    volumes:
      - $MGMT_DATA:/var/lib/netbird
      - $MGMT_JSON_FILE:/etc/netbird/management.json:ro
    networks: [$NB_DOCKER_NETWORK]
    # port 8080/4433 stay internal; put your proxy in front

  $DASH_SVC:
    image: docker.io/netbirdio/dashboard:latest
    restart: unless-stopped
    environment:
      - TZ=\${TZ}
      - NETBIRD_MGMT_API_ENDPOINT=http://$MGMT_SVC:8080
    depends_on: [$MGMT_SVC]
    networks: [$NB_DOCKER_NETWORK]
    # internal HTTP (proxy will forward external :64453 -> this service)

  $SIG_SVC:
    image: docker.io/netbirdio/signal:latest
    restart: unless-stopped
    environment:
      - TZ=\${TZ}
      - NB_SIGNAL_PORT=10000
    networks: [$NB_DOCKER_NETWORK]

networks:
  $NB_DOCKER_NETWORK:
    driver: bridge

secrets:
  masterkey:
    file: $MASTER_KEY_FILE
  zitadel-config:
    file: $NB_ETC/zitadel-secrets.yaml
EOF
}

write_zitadel_config_yaml() {
	# minimal bootstrap config for start-from-setup; DB creds from env
	cat >"$NB_ETC/zitadel-secrets.yaml" <<EOF
Database:
  postgres:
    Host: $ZITA_DB_SVC
    Port: 5432
    Database: \${POSTGRES_DB}
    MaxOpenConns: 20
    MaxIdleConns: 10
    MaxConnLifetime: 30m
    MaxConnIdleTime: 10m
    Admin:
      Username: \${POSTGRES_USER}
      Password: \${POSTGRES_PASSWORD}
    User:
      Username: zitadel
      Password: $(randpass)
FirstInstance:
  Org:
    Name: \${ZITADEL_FIRSTINSTANCE_ORG_NAME}
  Human:
    Username: \${ZITADEL_FIRSTINSTANCE_ORG_HUMAN_USERNAME}
    Password: \${ZITADEL_FIRSTINSTANCE_ORG_HUMAN_PASSWORD}
    Email:
      Address: \${ZITADEL_FIRSTINSTANCE_ORG_HUMAN_EMAIL}
      Verified: true
ExternalDomain: \${ZITADEL_EXTERNALDOMAIN}
ExternalSecure: \${ZITADEL_EXTERNALSECURE}
Notifications:
  SMTP:
    Host: \${ZITADEL_NOTIFICATIONS_SMTP_HOST}
    Port: \${ZITADEL_NOTIFICATIONS_SMTP_PORT}
    FromAddress: \${ZITADEL_NOTIFICATIONS_SMTP_FROM}
    TLS: \${ZITADEL_NOTIFICATIONS_SMTPTLS}
EOF
}

#######################################
# Admin ensure/reset (Zitadel)
#######################################
ensure_admin_user() {
	# We attempt a best-effort password (re)set for the human admin.
	# On first boot, ZITADEL will create the user via FirstInstance config.
	# On subsequent runs (existing DB), we try to change the password.
	# CLI inside container:
	#   zitadel users human change-password --org <org> --login-name <user@org.domain> --password <new>
	# CLI flags vary across versions; if it fails, we just print the next steps.

	login_name="$ADMIN_USER_LOCAL@$NB_ORG.$NB_DOMAIN"
	new_pass="$(cat "$ADMIN_PASS_FILE")"

	if docker compose -f "$DC_FILE" ps "$ZITADEL_SVC" >/dev/null 2>&1; then
		say "Attempting to (re)set admin password in ZITADEL for $login_name ..."
		if docker compose -f "$DC_FILE" exec -T "$ZITADEL_SVC" /bin/sh -c \
			"zitadel users human change-password --login-name '$login_name' --password '$new_pass'" 2>"$NB_LOG/zitadel_chpass.err"; then
			say "Admin password ensured in ZITADEL."
		else
			say "Could not change admin password automatically (CLI syntax may differ)."
			say "Manual step (inside zitadel container):"
			say "  zitadel users human change-password --login-name '$login_name' --password '$(cat "$ADMIN_PASS_FILE")'"
			say "See $NB_LOG/zitadel_chpass.err for details."
		fi
	fi
}

#######################################
# Main flow
#######################################
install_docker

ensure_admin_password
ensure_master_key
write_zitadel_env
write_netbird_env
write_management_json
write_zitadel_config_yaml
write_compose

# Compose exports
export COMPOSE_PROJECT_NAME=netbird

# Create network if missing
docker network inspect "$NB_DOCKER_NETWORK" >/dev/null 2>&1 || docker network create "$NB_DOCKER_NETWORK" >/dev/null

# Pull/update images and start
(
	cd "$NB_COMPOSE"
	# shellcheck disable=SC2046
	set -a
	. "$ZITADEL_ENV_FILE"
	. "$NETBIRD_ENV_FILE"
	set +a
	docker compose pull
	docker compose up -d
)

# Best-effort admin ensure/reset
ensure_admin_user

cat <<OUT

================================================================================
NetBird self-hosted stack is up (or updated) at: $NB_ROOT

Reverse proxy publishing guide (external -> internal):
  - https://$NB_DOMAIN:$NB_EXTERNAL_PORT   -> dashboard   -> http://$DASH_SVC:80
  - https://$NB_DOMAIN:$NB_EXTERNAL_PORT   -> management  -> http://$MGMT_SVC:8080
  - https://$NB_DOMAIN:$NB_EXTERNAL_PORT   -> zitadel     -> http://$ZITADEL_SVC:8080 (if you proxy it too)
  - TURN (udp/3478, udp/49152-49252) should be allowed between peers and $TURN_SVC (internal)

Admin account:
  - Username: ${ADMIN_USER_LOCAL}@${NB_ORG}.${NB_DOMAIN}
  - Password: $(cat "$ADMIN_PASS_FILE")
  - Stored at: $ADMIN_PASS_FILE

SMTP:
  - Using host MTA at ${NB_EMAIL_SMTP_HOST}:${NB_EMAIL_SMTP_PORT}, from=${NB_EMAIL_FROM_USER}

Next steps:
  1) Point your reverse proxy at the internal services above; expose EXTERNALLY on :${NB_EXTERNAL_PORT}.
  2) In ZITADEL, create a confidential OIDC app for NetBird (audience 'netbird'), then set in $MGMT_JSON_FILE:
       "ClientID": "<client-id>", "ClientSecret": "<client-secret>"
     and re-run: docker compose up -d
  3) Join clients using the dashboard once SSO is wired.

Re-run this script anytime to safely update images/configs. No data is destroyed.
================================================================================
OUT

exit 0
