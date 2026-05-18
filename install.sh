#!/bin/sh
# POSIX-compliant installer/updater for a self-hosted NetBird stack
# Components: ZITADEL (IdP), NetBird management, dashboard, signal, coturn (TURN)
# Repo reference: https://github.com/scriptmgr/netbird

set -eu

#######################################
# Helpers
#######################################
say() { printf '%s\n' "$*"; }
die() {
	say "ERROR: $*" >&2
	exit 1
}
have_cmd() { command -v "$1" >/dev/null 2>&1; }
need_cmd() { have_cmd "$1" || die "missing required command: $1"; }
as_root() { [ "$(id -u)" -eq 0 ] || die "please run as root (sudo sh ./install.sh)"; }

randpass() {
	length="${1:-24}"
	# Generate alphanumeric base one char shorter, then append a symbol.
	# ZITADEL's default complexity policy requires upper, lower, digit, and symbol.
	# Symbols chosen are safe in double-quoted env values and YAML scalars.
	base_len="$((length - 1))"
	if have_cmd openssl; then
		base=$(openssl rand -base64 48 | tr -d '\n' | tr -d '/+=' | cut -c1-"$base_len")
	else
		base=$(dd if=/dev/urandom bs=64 count=1 2>/dev/null | LC_ALL=C tr -dc 'A-Za-z0-9' | cut -c1-"$base_len")
	fi
	rand_byte=$(dd if=/dev/urandom bs=1 count=1 2>/dev/null | od -An -tu1 | tr -dc '0-9')
	symbols='!@#%*_-'
	sym=$(printf '%s' "$symbols" | cut -c"$(( (rand_byte % 7) + 1 ))")
	printf '%s%s\n' "$base" "$sym"
}

read_value() {
	file="$1"
	[ -r "$file" ] || die "unable to read required file: $file"
	tr -d '\n' <"$file"
}

ensure_secret_file() {
	file="$1"
	length="$2"
	label="$3"
	if [ ! -s "$file" ]; then
		(
			umask 077
			printf '%s\n' "$(randpass "$length")" >"$file"
		)
		say "Generated $label at $file"
	fi
}

# DataStoreEncryptionKey must be standard base64 of exactly 32 random bytes
# (AES-256 key). randpass() produces an arbitrary string that is not valid
# base64 so it cannot be used here.
ensure_datastore_key() {
	if [ ! -s "$DATASTORE_KEY_FILE" ]; then
		need_cmd openssl
		(
			umask 077
			openssl rand -base64 32 >"$DATASTORE_KEY_FILE"
		)
		say "Generated NetBird datastore key at $DATASTORE_KEY_FILE"
	fi
}

ensure_value_file() {
	file="$1"
	value="$2"
	label="$3"
	if [ ! -s "$file" ]; then
		(
			umask 077
			printf '%s\n' "$value" >"$file"
		)
		say "Initialized $label at $file"
	fi
}

selinux_enabled() {
	if have_cmd getenforce; then
		mode="$(getenforce 2>/dev/null || printf 'Disabled')"
		[ "$mode" != "Disabled" ]
	else
		return 1
	fi
}

bind_rw_opts() {
	if selinux_enabled; then
		printf 'rw,Z'
	else
		printf 'rw'
	fi
}

bind_ro_opts() {
	if selinux_enabled; then
		printf 'ro,Z'
	else
		printf 'ro'
	fi
}

firewall_open_port() {
	port_spec="$1"
	firewall-cmd --quiet --query-port="$port_spec" >/dev/null 2>&1 || firewall-cmd --quiet --permanent --add-port="$port_spec"
}

wait_for_http() {
	url="$1"
	label="$2"
	# Optional: host header override (for ZITADEL instance lookup by domain name)
	host_hdr="${3:-}"
	attempt=1
	while [ "$attempt" -le 60 ]; do
		if [ -n "$host_hdr" ]; then
			http_code="$(curl -ksS -H "Host: $host_hdr" -o /dev/null -w '%{http_code}' "$url" 2>/dev/null || printf '000')"
		else
			http_code="$(curl -ksS -o /dev/null -w '%{http_code}' "$url" 2>/dev/null || printf '000')"
		fi
		case "$http_code" in
			2*) return 0 ;;
		esac
		sleep 2
		attempt=$((attempt + 1))
	done
	die "timed out waiting for $label at $url"
}

wait_for_container_exec() {
	service="$1"
	attempt=1
	while [ "$attempt" -le 60 ]; do
		if docker compose -f "$DC_FILE" exec -T "$service" /bin/sh -c 'exit 0' >/dev/null 2>&1; then
			return 0
		fi
		sleep 2
		attempt=$((attempt + 1))
	done
	die "timed out waiting for container: $service"
}

os_id() {
	if [ -f /etc/os-release ]; then
		(
			. /etc/os-release
			printf '%s' "${ID:-unknown}"
		)
	else
		printf 'unknown'
	fi
}

#######################################
# Config defaults (override via env before running)
#######################################
: "${NB_ROOT:=/opt/netbird}"
: "${NB_DOMAIN:=vpn2me.us}"
: "${NB_ORG:=netbird}"
: "${NB_EXTERNAL_PORT:=64453}"
: "${NB_EMAIL_SMTP_HOST:=127.0.0.1}"
: "${NB_EMAIL_SMTP_PORT:=25}"
: "${NB_EMAIL_FROM_USER:=no-reply@$NB_DOMAIN}"
: "${NB_TIMEZONE:=America/New_York}"
: "${NB_DOCKER_NETWORK:=netbird}"
: "${NB_EMAIL_FROM_NAME:=CasjaysDev NetBird}"
: "${NB_DASHBOARD_BACKEND_PORT:=18080}"
: "${NB_MANAGEMENT_HTTP_BACKEND_PORT:=18081}"
: "${NB_ZITADEL_BACKEND_PORT:=18082}"
: "${NB_SIGNAL_BACKEND_PORT:=10000}"
: "${NB_TURN_PORT:=3478}"
: "${NB_TURN_MIN_PORT:=49152}"
: "${NB_TURN_MAX_PORT:=49252}"
: "${NB_AUTH_CLIENT_ID:=replace-me-client-id}"
: "${NB_AUTH_CLIENT_SECRET:=replace-me-client-secret}"
: "${NB_IDP_MGMT_CLIENT_ID:=replace-me-management-client-id}"
: "${NB_IDP_MGMT_CLIENT_SECRET:=replace-me-management-client-secret}"
: "${NB_AUTH_SUPPORTED_SCOPES:=openid profile email offline_access}"

NB_ETC="$NB_ROOT/etc"
NB_DATA="$NB_ROOT/data"
NB_SECRETS="$NB_ROOT/secrets"
NB_COMPOSE="$NB_ROOT/compose"
NB_STATE="$NB_ROOT/state"
NB_LOG="$NB_ROOT/log"

ZITADEL_DATA="$NB_DATA/zitadel"
ZITA_DB_DATA="$NB_DATA/postgres"
TURN_DATA="$NB_DATA/turn"
MGMT_DATA="$NB_DATA/management"
SIGNAL_DATA="$NB_DATA/signal"

ADMIN_USER_LOCAL="administrator"
TURN_USER_LOCAL="netbird"

ADMIN_PASS_FILE="$NB_SECRETS/admin_password"
MASTER_KEY_FILE="$NB_SECRETS/zitadel_master_key"
POSTGRES_PASS_FILE="$NB_SECRETS/postgres_password"
ZITADEL_DB_PASS_FILE="$NB_SECRETS/zitadel_db_password"
TURN_PASS_FILE="$NB_SECRETS/turn_password"
TURN_USER_FILE="$NB_SECRETS/turn_user"
DATASTORE_KEY_FILE="$NB_SECRETS/netbird_datastore_key"

ZITADEL_ENV_FILE="$NB_ETC/zitadel.env"
NETBIRD_ENV_FILE="$NB_ETC/netbird.env"
DASHBOARD_ENV_FILE="$NB_ETC/dashboard.env"
TURN_CONF_FILE="$NB_ETC/turnserver.conf"
MGMT_JSON_FILE="$NB_ETC/management.json"
DC_FILE="$NB_COMPOSE/docker-compose.yml"

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
need_cmd curl
need_cmd grep
need_cmd install
need_cmd printf
need_cmd sed
need_cmd systemctl
need_cmd uname

mkdir -p "$NB_ETC" "$NB_DATA" "$NB_SECRETS" "$NB_COMPOSE" "$NB_STATE" "$NB_LOG" "$ZITADEL_DATA" "$ZITA_DB_DATA" "$TURN_DATA" "$MGMT_DATA" "$SIGNAL_DATA"
chmod 700 "$NB_SECRETS"

#######################################
# Install/Upgrade Docker Engine (official repos)
#######################################
install_docker() {
	if have_cmd docker; then
		say "Docker already present. Ensuring Compose plugin is available..."
	fi

	case "$(uname -s)" in
	Linux)
		linux_id="$(os_id)"
		case "$linux_id" in
		ubuntu | debian | raspbian)
			need_cmd apt-get
			if dpkg -l | grep -qE '^ii[[:space:]]+docker\.io'; then
				say "Removing docker.io package to avoid conflicts..."
				apt-get remove -y docker.io
			fi
			apt-get update -y
			need_cmd gpg
			install -m 0755 -d /etc/apt/keyrings
			if [ ! -f /etc/apt/keyrings/docker.gpg ]; then
				curl -fsSL "https://download.docker.com/linux/$linux_id/gpg" | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
				chmod a+r /etc/apt/keyrings/docker.gpg
			fi
			codename="$(
				. /etc/os-release
				printf '%s' "$VERSION_CODENAME"
			)"
			printf 'deb [arch=%s signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/%s %s stable\n' "$(dpkg --print-architecture)" "$linux_id" "$codename" >/etc/apt/sources.list.d/docker.list
			apt-get update -y
			apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
			systemctl enable --now docker
			;;
		fedora)
			need_cmd dnf
			dnf -y install dnf-plugins-core
			dnf config-manager --add-repo https://download.docker.com/linux/fedora/docker-ce.repo
			dnf -y install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
			systemctl enable --now docker
			;;
		almalinux | rocky | centos | rhel | ol)
			need_cmd dnf
			dnf -y install dnf-plugins-core
			dnf config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo
			dnf -y install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
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
			say "Unknown distro '$linux_id'. Attempting to use existing Docker if available."
			;;
		esac
		;;
	*)
		die "Unsupported OS: $(uname -s) (Linux required for server components)"
		;;
	esac

	have_cmd docker || die "Docker not installed"
	docker compose version >/dev/null 2>&1 || die "Docker Compose plugin not found (docker compose)."
	systemctl is-enabled docker >/dev/null 2>&1 || systemctl enable docker
	systemctl is-active docker >/dev/null 2>&1 || systemctl start docker
}

#######################################
# Host integration
#######################################
configure_host_integration() {
	case "$(os_id)" in
	almalinux | rocky | centos | rhel | ol)
		need_cmd dnf
		dnf -y install firewalld policycoreutils-python-utils container-selinux
		systemctl enable --now firewalld
		;;
	esac

	if have_cmd firewall-cmd; then
		firewall_open_port "$NB_EXTERNAL_PORT/tcp"
		firewall_open_port "$NB_TURN_PORT/udp"
		firewall_open_port "$NB_TURN_MIN_PORT-$NB_TURN_MAX_PORT/udp"
		firewall-cmd --quiet --reload
	fi
}

#######################################
# Generate secrets and config
#######################################
ensure_runtime_secrets() {
	ensure_secret_file "$ADMIN_PASS_FILE" 24 "admin password"
	ensure_secret_file "$MASTER_KEY_FILE" 32 "ZITADEL master key"
	ensure_secret_file "$POSTGRES_PASS_FILE" 32 "Postgres password"
	ensure_secret_file "$ZITADEL_DB_PASS_FILE" 32 "ZITADEL database password"
	ensure_secret_file "$TURN_PASS_FILE" 32 "TURN password"
	ensure_datastore_key
	ensure_value_file "$TURN_USER_FILE" "$TURN_USER_LOCAL" "TURN username"
}

write_zitadel_env() {
	cat >"$ZITADEL_ENV_FILE" <<EOF
# Autogenerated by install.sh
TZ="$NB_TIMEZONE"

POSTGRES_USER=root
POSTGRES_PASSWORD=$(read_value "$POSTGRES_PASS_FILE")
POSTGRES_DB=zitadel

ZITADEL_MASTERKEY="$(read_value "$MASTER_KEY_FILE")"
ZITADEL_TLS_MODE=external
ZITADEL_FIRSTINSTANCE_ORG_NAME="$NB_ORG"
ZITADEL_FIRSTINSTANCE_ORG_HUMAN_USERNAME="$ADMIN_USER_LOCAL"
ZITADEL_FIRSTINSTANCE_ORG_HUMAN_PASSWORD="$(read_value "$ADMIN_PASS_FILE")"
ZITADEL_FIRSTINSTANCE_ORG_HUMAN_EMAIL="admin@$NB_DOMAIN"
ZITADEL_EXTERNALPORT="$NB_EXTERNAL_PORT"
ZITADEL_EXTERNALDOMAIN="$NB_DOMAIN"
ZITADEL_EXTERNALSECURE=true
ZITADEL_DATABASE_POSTGRES_HOST="$ZITA_DB_SVC"
ZITADEL_DATABASE_POSTGRES_PORT=5432
ZITADEL_DATABASE_POSTGRES_DATABASE=zitadel
ZITADEL_DATABASE_POSTGRES_USER_USERNAME=zitadel
ZITADEL_DATABASE_POSTGRES_USER_PASSWORD="$(read_value "$ZITADEL_DB_PASS_FILE")"
ZITADEL_DATABASE_POSTGRES_USER_SSL_MODE=disable
ZITADEL_DATABASE_POSTGRES_ADMIN_USERNAME=root
ZITADEL_DATABASE_POSTGRES_ADMIN_PASSWORD="$(read_value "$POSTGRES_PASS_FILE")"
ZITADEL_DATABASE_POSTGRES_ADMIN_SSL_MODE=disable

ZITADEL_NOTIFICATIONS_SMTPTLS=false
ZITADEL_NOTIFICATIONS_SMTP_FROM="$NB_EMAIL_FROM_USER"
ZITADEL_NOTIFICATIONS_SMTP_PORT="$NB_EMAIL_SMTP_PORT"
ZITADEL_NOTIFICATIONS_SMTP_HOST="$NB_EMAIL_SMTP_HOST"
ZITADEL_NOTIFICATIONS_SMTPSENDERNAME="$NB_EMAIL_FROM_NAME"
EOF
}

write_netbird_env() {
	if [ -f "$NETBIRD_ENV_FILE" ]; then
		return 0
	fi
	cat >"$NETBIRD_ENV_FILE" <<EOF
# Autogenerated by install.sh
TZ="$NB_TIMEZONE"

NB_AUTH_ISSUER=https://$NB_DOMAIN:$NB_EXTERNAL_PORT
NB_AUTH_OIDC_CONFIGURATION_ENDPOINT=https://$NB_DOMAIN:$NB_EXTERNAL_PORT/.well-known/openid-configuration
NB_AUTH_TOKEN_ENDPOINT=https://$NB_DOMAIN:$NB_EXTERNAL_PORT/oauth/v2/token
NB_AUTH_CLIENT_ID=$NB_AUTH_CLIENT_ID
NB_AUTH_CLIENT_SECRET=$NB_AUTH_CLIENT_SECRET
NB_IDP_MGMT_CLIENT_ID=$NB_IDP_MGMT_CLIENT_ID
NB_IDP_MGMT_CLIENT_SECRET=$NB_IDP_MGMT_CLIENT_SECRET
NB_AUTH_SUPPORTED_SCOPES="$NB_AUTH_SUPPORTED_SCOPES"

NETBIRD_EMAIL_SMTP_HOST="$NB_EMAIL_SMTP_HOST"
NETBIRD_EMAIL_SMTP_PORT="$NB_EMAIL_SMTP_PORT"
NETBIRD_EMAIL_FROM="$NB_EMAIL_FROM_USER"
EOF
}

write_dashboard_env() {
	cat >"$DASHBOARD_ENV_FILE" <<EOF
# Autogenerated by install.sh
NETBIRD_MGMT_API_ENDPOINT=https://$NB_DOMAIN:$NB_EXTERNAL_PORT
NETBIRD_MGMT_GRPC_API_ENDPOINT=https://$NB_DOMAIN:$NB_EXTERNAL_PORT
AUTH_AUDIENCE=$NB_AUTH_CLIENT_ID
AUTH_CLIENT_ID=$NB_AUTH_CLIENT_ID
AUTH_CLIENT_SECRET=$NB_AUTH_CLIENT_SECRET
AUTH_AUTHORITY=$NB_AUTH_ISSUER
USE_AUTH0=false
AUTH_SUPPORTED_SCOPES="$NB_AUTH_SUPPORTED_SCOPES"
AUTH_REDIRECT_URI=/nb-auth
AUTH_SILENT_REDIRECT_URI=/nb-silent-auth
NGINX_SSL_PORT=$NB_EXTERNAL_PORT
EOF
}

write_turnserver_conf() {
	cat >"$TURN_CONF_FILE" <<EOF
# Autogenerated by install.sh
listening-port=$NB_TURN_PORT
min-port=$NB_TURN_MIN_PORT
max-port=$NB_TURN_MAX_PORT
realm=$NB_DOMAIN
fingerprint
lt-cred-mech
stale-nonce=600
no-cli
no-loopback-peers
no-multicast-peers
user=$(read_value "$TURN_USER_FILE"):$(read_value "$TURN_PASS_FILE")
log-file=stdout
EOF
}

write_management_json() {
	cat >"$MGMT_JSON_FILE" <<EOF
{
  "Stuns": [
    {
      "Proto": "udp",
      "URI": "stun:$NB_DOMAIN:$NB_TURN_PORT",
      "Username": "",
      "Password": null
    }
  ],
  "TURNConfig": {
    "Turns": [
      {
        "Proto": "udp",
        "URI": "turn:$NB_DOMAIN:$NB_TURN_PORT",
        "Username": "$(read_value "$TURN_USER_FILE")",
        "Password": "$(read_value "$TURN_PASS_FILE")"
      }
    ],
    "CredentialsTTL": "12h",
    "Secret": "$(read_value "$TURN_PASS_FILE")",
    "TimeBasedCredentials": false
  },
  "Signal": {
    "Proto": "https",
    "URI": "$NB_DOMAIN:$NB_EXTERNAL_PORT",
    "Username": "",
    "Password": null
  },
  "ReverseProxy": {
    "TrustedHTTPProxies": [],
    "TrustedHTTPProxiesCount": 0,
    "TrustedPeers": [
      "0.0.0.0/0"
    ]
  },
  "DataStoreEncryptionKey": "$(read_value "$DATASTORE_KEY_FILE")",
  "HttpConfig": {
    "Address": "0.0.0.0:8080",
    "AuthIssuer": "$NB_AUTH_ISSUER",
    "AuthAudience": "$NB_AUTH_CLIENT_ID",
    "IdpSignKeyRefreshEnabled": true,
    "OIDCConfigEndpoint": "http://$NB_DOMAIN:8080/.well-known/openid-configuration"
  },
  "IdpManagerConfig": {
    "ManagerType": "zitadel",
    "ClientConfig": {
      "Issuer": "$NB_AUTH_ISSUER",
      "TokenEndpoint": "http://$NB_DOMAIN:8080/oauth/v2/token",
      "ClientID": "$NB_IDP_MGMT_CLIENT_ID",
      "ClientSecret": "$NB_IDP_MGMT_CLIENT_SECRET",
      "GrantType": "client_credentials"
    },
    "ExtraConfig": {
      "ManagementEndpoint": "http://$NB_DOMAIN:8080/management/v1"
    }
  },
  "PKCEAuthorizationFlow": {
    "ProviderConfig": {
      "Audience": "$NB_AUTH_CLIENT_ID",
      "ClientID": "$NB_AUTH_CLIENT_ID",
      "ClientSecret": "$NB_AUTH_CLIENT_SECRET",
      "AuthorizationEndpoint": "$NB_AUTH_ISSUER/oauth/v2/authorize",
      "TokenEndpoint": "$NB_AUTH_TOKEN_ENDPOINT",
      "Scope": "$NB_AUTH_SUPPORTED_SCOPES",
      "RedirectURLs": [
        "http://localhost:53000/",
        "http://localhost:54000/"
      ],
      "UseIDToken": false
    }
  }
}
EOF
}

write_compose() {
	rw_opts="$(bind_rw_opts)"
	ro_opts="$(bind_ro_opts)"
	cat >"$DC_FILE" <<EOF
# Autogenerated by install.sh — NetBird self-hosted stack
name: netbird
services:
  $ZITA_DB_SVC:
    image: docker.io/postgres:16-alpine
    restart: unless-stopped
    env_file:
      - $ZITADEL_ENV_FILE
    volumes:
      - $ZITA_DB_DATA:/var/lib/postgresql/data:$rw_opts
    networks: [$NB_DOCKER_NETWORK]
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U \$\$POSTGRES_USER -d \$\$POSTGRES_DB"]
      interval: 10s
      timeout: 5s
      retries: 12

  $ZITADEL_SVC:
    image: ghcr.io/zitadel/zitadel:v2.64.1
    depends_on:
      $ZITA_DB_SVC:
        condition: service_healthy
    restart: unless-stopped
    env_file:
      - $ZITADEL_ENV_FILE
    command: >
      start-from-init
      --masterkeyFromEnv
      --tlsMode external
    volumes:
      - $ZITADEL_DATA:/zitadel:$rw_opts
    ports:
      - 127.0.0.1:$NB_ZITADEL_BACKEND_PORT:8080
    networks:
      $NB_DOCKER_NETWORK:
        aliases:
          - $NB_DOMAIN

  $TURN_SVC:
    image: docker.io/coturn/coturn:latest
    restart: unless-stopped
    network_mode: host
    command:
      - -c
      - /etc/turnserver.conf
    volumes:
      - $TURN_CONF_FILE:/etc/turnserver.conf:$ro_opts
      - $TURN_DATA:/var/lib/coturn:$rw_opts

  $MGMT_SVC:
    image: docker.io/netbirdio/management:latest
    depends_on:
      $ZITA_DB_SVC:
        condition: service_healthy
      $ZITADEL_SVC:
        condition: service_started
    restart: unless-stopped
    command:
      - --port
      - "8080"
      - --config
      - /etc/netbird/management.json
      - --datadir
      - /var/lib/netbird
      - --log-file
      - console
      - --log-level
      - info
      - --disable-anonymous-metrics=true
      - --single-account-mode-domain=$NB_DOMAIN
      - --dns-domain=$NB_DOMAIN
      - --idp-sign-key-refresh-enabled
    environment:
      - TZ=$NB_TIMEZONE
    volumes:
      - $MGMT_DATA:/var/lib/netbird:$rw_opts
      - $MGMT_JSON_FILE:/etc/netbird/management.json:$ro_opts
    ports:
      - 127.0.0.1:$NB_MANAGEMENT_HTTP_BACKEND_PORT:8080
    networks: [$NB_DOCKER_NETWORK]

  $DASH_SVC:
    image: docker.io/netbirdio/dashboard:latest
    restart: unless-stopped
    env_file:
      - $DASHBOARD_ENV_FILE
    depends_on:
      - $MGMT_SVC
    ports:
      - 127.0.0.1:$NB_DASHBOARD_BACKEND_PORT:80
    networks: [$NB_DOCKER_NETWORK]

  $SIG_SVC:
    image: docker.io/netbirdio/signal:latest
    restart: unless-stopped
    environment:
      - TZ=$NB_TIMEZONE
      - NB_SIGNAL_PORT=10000
    volumes:
      - $SIGNAL_DATA:/var/lib/netbird:$rw_opts
    ports:
      - 127.0.0.1:$NB_SIGNAL_BACKEND_PORT:10000
    networks: [$NB_DOCKER_NETWORK]

networks:
  $NB_DOCKER_NETWORK:
    driver: bridge
EOF
}

#######################################
# Validation and admin bootstrap
#######################################
validate_compose_definition() {
	(
		cd "$NB_COMPOSE"
		set -a
		. "$ZITADEL_ENV_FILE"
		. "$NETBIRD_ENV_FILE"
		set +a
		docker compose config >/dev/null
	)
}

validate_running_services() {
	say "Waiting for all services to reach running state (up to 5 minutes)..."
	attempt=1
	while [ "$attempt" -le 60 ]; do
		all_running=1
		running_services="$(docker compose -f "$DC_FILE" ps --services --status running 2>/dev/null)"
		for service in "$ZITA_DB_SVC" "$ZITADEL_SVC" "$TURN_SVC" "$MGMT_SVC" "$DASH_SVC" "$SIG_SVC"; do
			if ! printf '%s\n' "$running_services" | grep -qx "$service"; then
				all_running=0
				break
			fi
		done
		[ "$all_running" -eq 1 ] && return 0
		sleep 5
		attempt=$((attempt + 1))
	done
	# Final pass — report which service(s) failed
	running_services="$(docker compose -f "$DC_FILE" ps --services --status running 2>/dev/null)"
	for service in "$ZITA_DB_SVC" "$ZITADEL_SVC" "$TURN_SVC" "$MGMT_SVC" "$DASH_SVC" "$SIG_SVC"; do
		printf '%s\n' "$running_services" | grep -qx "$service" || die "service did not reach running state: $service"
	done
}

ensure_admin_user() {
	# ZITADEL is distroless (no shell) and this version has no 'users' CLI subcommand.
	# The admin account is bootstrapped correctly on first start via
	# ZITADEL_FIRSTINSTANCE_ORG_HUMAN_PASSWORD in the generated env file.
	# Secret files are preserved across reruns so the credentials never rotate unintentionally.
	say "ZITADEL admin bootstrapped via env. Credentials:"
	say "  Login:    ${ADMIN_USER_LOCAL}@${NB_ORG}.${NB_DOMAIN}"
	say "  Password: see $ADMIN_PASS_FILE"
}

#######################################
# Main flow
#######################################
install_docker
configure_host_integration
ensure_runtime_secrets

write_zitadel_env
write_netbird_env

set -a
. "$ZITADEL_ENV_FILE"
. "$NETBIRD_ENV_FILE"
set +a

write_dashboard_env
write_turnserver_conf
write_management_json
write_compose
validate_compose_definition

docker network inspect "$NB_DOCKER_NETWORK" >/dev/null 2>&1 || docker network create "$NB_DOCKER_NETWORK" >/dev/null

(
	cd "$NB_COMPOSE"
	set -a
	. "$ZITADEL_ENV_FILE"
	. "$NETBIRD_ENV_FILE"
	set +a
	docker compose pull
	docker compose up -d
)

validate_running_services
wait_for_http "http://127.0.0.1:$NB_ZITADEL_BACKEND_PORT/.well-known/openid-configuration" "ZITADEL OIDC configuration" "$NB_DOMAIN"
wait_for_http "http://127.0.0.1:$NB_DASHBOARD_BACKEND_PORT/" "NetBird dashboard"
ensure_admin_user

cat <<OUT

================================================================================
NetBird self-hosted stack is up (or updated) at: $NB_ROOT

Host integration:
  - Firewalld opened: tcp/$NB_EXTERNAL_PORT, udp/$NB_TURN_PORT, udp/$NB_TURN_MIN_PORT-$NB_TURN_MAX_PORT
  - SELinux bind relabeling: $(if selinux_enabled; then printf 'enabled'; else printf 'not required'; fi)

Local reverse-proxy backends:
  - Dashboard root                          -> http://127.0.0.1:$NB_DASHBOARD_BACKEND_PORT
  - Management REST / websocket proxy       -> http://127.0.0.1:$NB_MANAGEMENT_HTTP_BACKEND_PORT
  - Zitadel OIDC / UI                       -> http://127.0.0.1:$NB_ZITADEL_BACKEND_PORT
  - Signal                                  -> http://127.0.0.1:$NB_SIGNAL_BACKEND_PORT
  - TURN                                    -> udp/$NB_TURN_PORT and udp/$NB_TURN_MIN_PORT-$NB_TURN_MAX_PORT

Admin account:
  - Username: ${ADMIN_USER_LOCAL}@${NB_ORG}.${NB_DOMAIN}
  - Password file: $ADMIN_PASS_FILE

Important config files:
  - Zitadel bootstrap env:   $ZITADEL_ENV_FILE
  - NetBird env:             $NETBIRD_ENV_FILE
  - Dashboard env:           $DASHBOARD_ENV_FILE
  - Management config:       $MGMT_JSON_FILE
  - Coturn config:           $TURN_CONF_FILE

Next manual production step:
  - Fill NB_AUTH_CLIENT_ID, NB_AUTH_CLIENT_SECRET, NB_IDP_MGMT_CLIENT_ID, and
    NB_IDP_MGMT_CLIENT_SECRET in $NETBIRD_ENV_FILE, then rerun this script.

This script is idempotent for reruns: generated secrets, database credentials,
and datastore encryption keys are preserved unless you replace the files
under $NB_SECRETS yourself.
================================================================================
OUT

if grep -q 'replace-me' "$NETBIRD_ENV_FILE" 2>/dev/null; then
	say ""
	say "WARNING: OIDC credentials are still placeholders in $NETBIRD_ENV_FILE"
	say "  NetBird authentication will not work until you set:"
	say "    NB_AUTH_CLIENT_ID, NB_AUTH_CLIENT_SECRET,"
	say "    NB_IDP_MGMT_CLIENT_ID, NB_IDP_MGMT_CLIENT_SECRET"
	say "  then rerun this script."
fi

exit 0
