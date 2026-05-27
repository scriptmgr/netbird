#!/usr/bin/env sh
# shellcheck shell=sh
# - - - - - - - - - - - - - - - - - - - - - - - - -
##@Version           :  202605191052-git
# @@Author           :  Jason Hempstead
# @@Contact          :  git-admin@casjaysdev.pro
# @@License          :  MIT or LICENSE.md
# @@ReadME           :  install.sh --help | README.md
# @@Copyright        :  Copyright: (c) 2026 Jason Hempstead, Casjays Developments
# @@Created          :  Wednesday, November 19, 2025 00:00 UTC
# @@File             :  install.sh
# @@Description      :  NetBird self-hosted stack installer and updater
# @@Changelog        :  New script
# @@TODO             :  See README.md
# @@Other            :
# @@Resource         :  https://netbird.io
# @@Terminal App     :  yes
# @@sudo/root        :  yes
# @@Template         :  shell/sh
# - - - - - - - - - - - - - - - - - - - - - - - - -
# shellcheck disable=SC1001,SC1003,SC2001,SC2003,SC2016,SC2031,SC2090,SC2115,SC2120,SC2155,SC2199,SC2229,SC2317,SC2329
# - - - - - - - - - - - - - - - - - - - - - - - - -

VERSION="202605191052-git"

APPNAME="${0##*/}"
RUN_USER="${USER}"
SET_UID="$(id -u)"
SCRIPT_SRC_DIR="$(cd -- "$(dirname -- "$0")" && pwd)"

set -eu

# - - - - - - - - - - - - - - - - - - - - - - - - -
# Helpers
__say() { printf '%s\n' "$*"; }
__die() {
	__say "ERROR: $*" >&2
	exit 1
}
__have_cmd() { command -v "$1" >/dev/null 2>&1; }
__need_cmd() { __have_cmd "$1" || __die "missing required command: $1"; }
__as_root() { [ "$(id -u)" -eq 0 ] || __die "please run as root (sudo sh ./install.sh)"; }

# __detect_fqdn — try hostname -d (domain part) then hostname -f (full qualified)
__detect_fqdn() {
	d=$(hostname -d 2>/dev/null | tr -d '[:space:]')
	case "$d" in
		''|'(none)'|localdomain)
			d=$(hostname -f 2>/dev/null | tr -d '[:space:]')
			;;
	esac
	printf '%s' "$d"
}

# __validate__hosts_fqdn — return 0 if arg looks like a valid FQDN, 1 otherwise
__validate__hosts_fqdn() {
	fqdn="$1"
	[ -n "$fqdn" ] || return 1
	# must contain at least one dot
	case "$fqdn" in
		*.*) ;;
		*) return 1 ;;
	esac
	# reject leading/trailing/double dot or embedded space
	case "$fqdn" in
		'.'*|*'.'|*'..'*|*' '*) return 1 ;;
	esac
	printf '%s' "$fqdn" | grep -qE -- '^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?)*\.[a-zA-Z]{2,}$'
}

__randpass() {
	length="${1:-24}"
	# Generate alphanumeric base one char shorter, then append a symbol.
	# Symbols chosen are safe in double-quoted env values and YAML scalars.
	base_len="$((length - 1))"
	if __have_cmd openssl; then
		base=$(openssl rand -base64 48 | tr -d '\n' | tr -d '/+=' | cut -c1-"$base_len")
	else
		base=$(dd if=/dev/urandom bs=64 count=1 2>/dev/null | LC_ALL=C tr -dc 'A-Za-z0-9' | cut -c1-"$base_len")
	fi
	rand_byte=$(dd if=/dev/urandom bs=1 count=1 2>/dev/null | od -An -tu1 | tr -dc '0-9')
	symbols='!@#*_-'
	sym=$(printf '%s' "$symbols" | cut -c"$(( (rand_byte % 6) + 1 ))")
	printf '%s%s\n' "$base" "$sym"
}

__read_value() {
	file="$1"
	[ -r "$file" ] || __die "unable to read required file: $file"
	tr -d '\n' <"$file"
}

__ensure_secret_file() {
	file="$1"
	length="$2"
	label="$3"
	if [ ! -s "$file" ]; then
		(
			umask 077
			printf '%s\n' "$(__randpass "$length")" >"$file"
		)
		__say "Generated $label at $file"
	fi
}

# DataStoreEncryptionKey must be standard base64 of exactly 32 random bytes
# (AES-256 key). __randpass() produces an arbitrary string that is not valid
# base64 so it cannot be used here.
__ensure_datastore_key() {
	if [ ! -s "$DATASTORE_KEY_FILE" ]; then
		__need_cmd openssl
		(
			umask 077
			openssl rand -base64 32 >"$DATASTORE_KEY_FILE"
		)
		__say "Generated NetBird datastore key at $DATASTORE_KEY_FILE"
	fi
}

__ensure_value_file() {
	file="$1"
	value="$2"
	label="$3"
	if [ ! -s "$file" ]; then
		(
			umask 077
			printf '%s\n' "$value" >"$file"
		)
		__say "Initialized $label at $file"
	fi
}

# __json_field KEY JSON_STRING
# Extracts a top-level string field from a JSON object using python3.
__json_field() {
	key="$1"
	input="$2"
	printf '%s' "$input" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('$key',''), end='')" 2>/dev/null || printf ''
}

__selinux_enabled() {
	if __have_cmd getenforce; then
		mode="$(getenforce 2>/dev/null || printf 'Disabled')"
		[ "$mode" != "Disabled" ]
	else
		return 1
	fi
}

__bind_rw_opts() {
	if __selinux_enabled; then
		printf 'rw,Z'
	else
		printf 'rw'
	fi
}

__bind_ro_opts() {
	if __selinux_enabled; then
		printf 'ro,Z'
	else
		printf 'ro'
	fi
}

__firewall_open_port() {
	port_spec="$1"
	firewall-cmd --quiet --query-port="$port_spec" >/dev/null 2>&1 || firewall-cmd --quiet --permanent --add-port="$port_spec"
}

__wait_for_http() {
	url="$1"
	label="$2"
	attempt=1
	while [ "$attempt" -le 150 ]; do
		http_code="$(curl -ksS -o /dev/null -w '%{http_code}' "$url" 2>/dev/null || printf '000')"
		case "$http_code" in
			200) return 0 ;;
		esac
		sleep 2
		attempt=$((attempt + 1))
	done
	__die "timed out waiting for $label at $url"
}

__wait_for_container_exec() {
	service="$1"
	attempt=1
	while [ "$attempt" -le 60 ]; do
		if docker compose -f "$DC_FILE" exec -T "$service" /bin/sh -c 'exit 0' >/dev/null 2>&1; then
			return 0
		fi
		sleep 2
		attempt=$((attempt + 1))
	done
	__die "timed out waiting for container: $service"
}

__os_id() {
	if [ -f /etc/os-release ]; then
		(
			. /etc/os-release
			printf '%s' "${ID:-unknown}"
		)
	else
		printf 'unknown'
	fi
}

# - - - - - - - - - - - - - - - - - - - - - - - - -
# Config defaults (override via env before running)

# Load site-specific overrides from an .env file next to this script.
if [ -f "$SCRIPT_SRC_DIR/.env" ]; then
	set -a
	. "$SCRIPT_SRC_DIR/.env"
	set +a
fi

: "${NB_ROOT:=/opt/netbird}"
: "${NB_DOMAIN:=$(__detect_fqdn)}"
__validate__hosts_fqdn "$NB_DOMAIN" || __die "NB_DOMAIN='$NB_DOMAIN' is not a valid FQDN. Set NB_DOMAIN in .env or export it before running."
: "${NB_ORG:=netbird}"
: "${NB_EXTERNAL_PORT:=443}"
: "${NB_EMAIL_SMTP_HOST:=127.0.0.1}"
: "${NB_EMAIL_SMTP_PORT:=25}"
: "${NB_EMAIL_FROM_USER:=no-reply@$NB_DOMAIN}"
: "${NB_TIMEZONE:=America/New_York}"
: "${NB_DOCKER_NETWORK:=netbird}"
: "${NB_EMAIL_FROM_NAME:=NetBird}"
: "${NB_DASHBOARD_BACKEND_PORT:=18080}"
: "${NB_MANAGEMENT_HTTP_BACKEND_PORT:=18081}"
: "${NB_KC_BACKEND_PORT:=18082}"
: "${NB_KC_MGMT_PORT:=18083}"
: "${NB_SIGNAL_BACKEND_PORT:=10000}"
: "${NB_TURN_PORT:=3478}"
: "${NB_TURN_MIN_PORT:=49152}"
: "${NB_TURN_MAX_PORT:=49252}"
: "${NB_AUTH_CLIENT_ID:=replace-me}"
: "${NB_AUTH_CLIENT_SECRET:=}"
: "${NB_IDP_MGMT_CLIENT_ID:=replace-me}"
: "${NB_IDP_MGMT_CLIENT_SECRET:=replace-me}"
: "${NB_AUTH_SUPPORTED_SCOPES:=openid profile email offline_access}"
: "${NB_SSL_CERT:=/etc/letsencrypt/live/domain/fullchain.pem}"
: "${NB_SSL_KEY:=/etc/letsencrypt/live/domain/privkey.pem}"

NB_ETC="$NB_ROOT/etc"
NB_DATA="$NB_ROOT/data"
NB_SECRETS="$NB_ROOT/secrets"
NB_COMPOSE="$NB_ROOT/compose"
NB_STATE="$NB_ROOT/state"
NB_LOG="$NB_ROOT/log"

KC_DATA="$NB_DATA/keycloak"
KC_DB_DATA="$NB_DATA/keycloak-db"
TURN_DATA="$NB_DATA/turn"
MGMT_DATA="$NB_DATA/management"
SIGNAL_DATA="$NB_DATA/signal"

TURN_USER_LOCAL="netbird"

KC_ADMIN_PASS_FILE="$NB_SECRETS/kc_admin_password"
KC_DB_PASS_FILE="$NB_SECRETS/kc_db_password"
TURN_PASS_FILE="$NB_SECRETS/turn_password"
TURN_USER_FILE="$NB_SECRETS/turn_user"
DATASTORE_KEY_FILE="$NB_SECRETS/netbird_datastore_key"

KC_ENV_FILE="$NB_ETC/keycloak.env"
NETBIRD_ENV_FILE="$NB_ETC/netbird.env"
DASHBOARD_ENV_FILE="$NB_ETC/dashboard.env"
TURN_CONF_FILE="$NB_ETC/turnserver.conf"
MGMT_JSON_FILE="$NB_ETC/management.json"
DC_FILE="$NB_COMPOSE/docker-compose.yml"

KC_SVC="keycloak"
KC_DB_SVC="keycloak-db"
TURN_SVC="coturn"
MGMT_SVC="management"
DASH_SVC="dashboard"
SIG_SVC="signal"

# - - - - - - - - - - - - - - - - - - - - - - - - -
# Pre-flight
__as_root
__need_cmd awk
__need_cmd curl
__need_cmd grep
__need_cmd install
__need_cmd printf
__need_cmd python3
__need_cmd sed
__need_cmd systemctl
__need_cmd uname

mkdir -p "$NB_ETC" "$NB_DATA" "$NB_SECRETS" "$NB_COMPOSE" "$NB_STATE" "$NB_LOG" \
         "$KC_DATA" "$KC_DB_DATA" "$TURN_DATA" "$MGMT_DATA" "$SIGNAL_DATA"
chmod 700 "$NB_SECRETS"

# - - - - - - - - - - - - - - - - - - - - - - - - -
# Install/Upgrade Docker Engine (official repos)
__install_docker() {
	if __have_cmd docker && docker compose version >/dev/null 2>&1; then
		__say "Docker and Compose plugin already present — skipping installation."
		systemctl is-enabled docker >/dev/null 2>&1 || systemctl enable docker
		systemctl is-active docker >/dev/null 2>&1 || systemctl start docker
		return 0
	fi

	case "$(uname -s)" in
	Linux)
		linux_id="$(__os_id)"
		case "$linux_id" in
		ubuntu | debian | raspbian)
			__need_cmd apt-get
			if dpkg -l | grep -qE -- '^ii[[:space:]]+docker\.io'; then
				__say "Removing docker.io package to avoid conflicts..."
				apt-get remove -y docker.io
			fi
			apt-get update -y
			__need_cmd gpg
			install -m 0755 -d /etc/apt/keyrings
			if [ ! -f /etc/apt/keyrings/docker.gpg ]; then
				curl -fsSL "https://download.docker.com/linux/$linux_id/gpg" | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
				chmod a+r /etc/apt/keyrings/docker.gpg
			fi
			codename="$(
				. /etc/os-release
				printf '%s' "$VERSION_CODENAME"
			)"
			arch="$(dpkg --print-architecture)"
			printf 'deb [arch=%s signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/%s %s stable\n' \
				"$arch" "$linux_id" "$codename" >/etc/apt/sources.list.d/docker.list
			apt-get update -y
			apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
			systemctl enable --now docker
			;;
		fedora)
			__need_cmd dnf
			dnf -y install dnf-plugins-core
			dnf config-manager --add-repo https://download.docker.com/linux/fedora/docker-ce.repo
			dnf -y remove containerd 2>/dev/null || true
			dnf -y install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
			systemctl enable --now docker
			;;
		almalinux | rocky | centos | rhel | ol)
			__need_cmd dnf
			dnf -y install dnf-plugins-core
			dnf config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo
			dnf -y remove containerd 2>/dev/null || true
			dnf -y install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
			systemctl enable --now docker
			;;
		opensuse* | sles)
			__need_cmd zypper
			zypper refresh
			zypper -n install docker docker-compose
			systemctl enable --now docker
			# Distro docker-compose may be a standalone binary, not a CLI plugin.
			# Symlink it into the CLI plugin directory so 'docker compose' works.
			mkdir -p /usr/lib/docker/cli-plugins
			if [ ! -f /usr/lib/docker/cli-plugins/docker-compose ] && __have_cmd docker-compose; then
				ln -sf "$(command -v docker-compose)" /usr/lib/docker/cli-plugins/docker-compose
			fi
			;;
		arch | manjaro | endeavouros | arcolinux)
			__need_cmd pacman
			pacman -Sy --noconfirm docker docker-compose
			systemctl enable --now docker
			# Same as openSUSE: ensure the CLI plugin path is populated.
			mkdir -p /usr/lib/docker/cli-plugins
			if [ ! -f /usr/lib/docker/cli-plugins/docker-compose ] && __have_cmd docker-compose; then
				ln -sf "$(command -v docker-compose)" /usr/lib/docker/cli-plugins/docker-compose
			fi
			;;
		*)
			__say "Unknown distro '$linux_id'. Attempting to use existing Docker if available."
			;;
		esac
		;;
	*)
		__die "Unsupported OS: $(uname -s) (Linux required for server components)"
		;;
	esac

	__have_cmd docker || __die "Docker not installed"
	docker compose version >/dev/null 2>&1 || __die "Docker Compose plugin not found (docker compose)."
	systemctl is-enabled docker >/dev/null 2>&1 || systemctl enable docker
	systemctl is-active docker >/dev/null 2>&1 || systemctl start docker
}

# - - - - - - - - - - - - - - - - - - - - - - - - -
# Kernel modules and sysctl

# Required kernel modules for Docker bridge networking and WireGuard/NetBird peers.
NB_MODULES="overlay br_netfilter"
NB_MODULES_FILE="/etc/modules-load.d/netbird.conf"

# sysctl knobs required by Docker (bridge) and WireGuard (src_valid_mark, rp_filter).
# Stored in /etc/sysctl.d/99-netbird.conf; also checked/patched in /etc/sysctl.conf.
NB_SYSCTL_FILE="/etc/sysctl.d/99-netbird.conf"
# key=value pairs (POSIX, no arrays)
NB_SYSCTLS="
net.ipv4.ip_forward=1
net.bridge.bridge-nf-call-iptables=1
net.bridge.bridge-nf-call-ip6tables=1
net.ipv4.conf.all.src_valid_mark=1
net.ipv4.conf.all.rp_filter=0
net.ipv4.conf.default.rp_filter=0
"

# Ensure a sysctl key is set to the required value.
# Checks /etc/sysctl.conf first; if found with the right value, leaves it alone.
# If found with the wrong value, patches it in place.
# If not found, delegates to /etc/sysctl.d/99-netbird.conf.
__ensure_sysctl() {
	key="$1"
	val="$2"
	pat=$(printf '%s' "$key" | sed 's/\./\\./g')

	# Check /etc/sysctl.conf
	if grep -qE -- "^[[:space:]]*${pat}[[:space:]]*=" /etc/sysctl.conf 2>/dev/null; then
		cur=$(grep -E -- "^[[:space:]]*${pat}[[:space:]]*=" /etc/sysctl.conf | tail -1 | sed 's/.*=[[:space:]]*//')
		if [ "$cur" = "$val" ]; then
			# already correct in sysctl.conf
			return 0
		fi
		# Wrong value — patch it in sysctl.conf
		sed -i "s|^[[:space:]]*${pat}[[:space:]]*=.*|${key} = ${val}|" /etc/sysctl.conf
		__say "  sysctl.conf: updated ${key} = ${val}"
		return 0
	fi

	# Not in sysctl.conf — ensure it is in the drop-in file
	if grep -qE -- "^[[:space:]]*${pat}[[:space:]]*=" "$NB_SYSCTL_FILE" 2>/dev/null; then
		cur=$(grep -E -- "^[[:space:]]*${pat}[[:space:]]*=" "$NB_SYSCTL_FILE" | tail -1 | sed 's/.*=[[:space:]]*//')
		if [ "$cur" = "$val" ]; then
			# already correct in drop-in
			return 0
		fi
		sed -i "s|^[[:space:]]*${pat}[[:space:]]*=.*|${key} = ${val}|" "$NB_SYSCTL_FILE"
		__say "  99-netbird.conf: updated ${key} = ${val}"
	else
		printf '%s = %s\n' "$key" "$val" >>"$NB_SYSCTL_FILE"
		__say "  99-netbird.conf: added ${key} = ${val}"
	fi
}

__configure_kernel() {
	__say "Configuring kernel modules..."

	# --- modules-load.d ---
	for mod in $NB_MODULES; do
		# Persist in modules-load.d
		if ! grep -qx -- "$mod" "$NB_MODULES_FILE" 2>/dev/null; then
			printf '%s\n' "$mod" >>"$NB_MODULES_FILE"
			__say "  modules-load.d: added $mod"
		fi
		# Load now (no-op if already loaded)
		if ! grep -qx -- "$mod" /proc/modules 2>/dev/null && \
		   ! grep -q -- "^${mod} " /proc/modules 2>/dev/null; then
			modprobe "$mod" 2>/dev/null && __say "  modprobe: loaded $mod" || \
				__say "  modprobe: $mod unavailable (may already be built-in)"
		fi
	done

	# --- sysctl drop-in header (idempotent) ---
	if [ ! -f "$NB_SYSCTL_FILE" ]; then
		printf '# Managed by netbird install.sh — do not edit by hand\n' >"$NB_SYSCTL_FILE"
	fi

	# --- per-key check/patch ---
	__say "Configuring sysctl..."
	printf '%s\n' "$NB_SYSCTLS" | grep -v -- '^$' | while IFS='=' read -r k v; do
		__ensure_sysctl "$k" "$v"
	done

	# --- apply live ---
	sysctl --system >/dev/null 2>&1 && __say "  sysctl: settings applied" || \
		__say "  sysctl: --system apply failed, trying targeted apply"
	# Belt-and-suspenders: apply each key live even if --system failed
	printf '%s\n' "$NB_SYSCTLS" | grep -v -- '^$' | while IFS='=' read -r k v; do
		sysctl -w "${k}=${v}" >/dev/null 2>&1 || true
	done
}

# - - - - - - - - - - - - - - - - - - - - - - - - -
# Host integration
__configure_host_integration() {
	case "$(__os_id)" in
	almalinux | rocky | centos | rhel | ol)
		__need_cmd dnf
		dnf -y install firewalld policycoreutils-python-utils container-selinux
		systemctl enable --now firewalld
		if __selinux_enabled; then
			setsebool -P httpd_can_network_connect 1
			__say "SELinux: httpd_can_network_connect enabled (nginx → upstream proxying)"
		fi
		;;
	esac

	if __have_cmd firewall-cmd; then
		__firewall_open_port "$NB_EXTERNAL_PORT/tcp"
		__firewall_open_port "$NB_TURN_PORT/udp"
		__firewall_open_port "$NB_TURN_MIN_PORT-$NB_TURN_MAX_PORT/udp"
		firewall-cmd --quiet --reload
	fi
}

# - - - - - - - - - - - - - - - - - - - - - - - - -
# Generate secrets and config
__ensure_runtime_secrets() {
	__ensure_secret_file "$KC_ADMIN_PASS_FILE" 24 "Keycloak admin password"
	__ensure_secret_file "$KC_DB_PASS_FILE" 32 "Keycloak database password"
	__ensure_secret_file "$TURN_PASS_FILE" 32 "TURN password"
	__ensure_datastore_key
	__ensure_value_file "$TURN_USER_FILE" "$TURN_USER_LOCAL" "TURN username"
}

__write_keycloak_env() {
	cat >"$KC_ENV_FILE" <<EOF
# Autogenerated by install.sh
TZ="$NB_TIMEZONE"

POSTGRES_DB=keycloak
POSTGRES_USER=keycloak
POSTGRES_PASSWORD=$(__read_value "$KC_DB_PASS_FILE")

KC_DB=postgres
KC_DB_URL=jdbc:postgresql://$KC_DB_SVC:5432/keycloak
KC_DB_USERNAME=keycloak
KC_DB_PASSWORD=$(__read_value "$KC_DB_PASS_FILE")

KEYCLOAK_ADMIN=admin
KEYCLOAK_ADMIN_PASSWORD=$(__read_value "$KC_ADMIN_PASS_FILE")

KC_HOSTNAME=https://$NB_DOMAIN:$NB_EXTERNAL_PORT
KC_HTTP_ENABLED=true
KC_PROXY_HEADERS=xforwarded
KC_HOSTNAME_STRICT=false
KC_HEALTH_ENABLED=true
EOF
}

__write_netbird_env() {
	if [ -f "$NETBIRD_ENV_FILE" ]; then
		return 0
	fi
	cat >"$NETBIRD_ENV_FILE" <<EOF
# Autogenerated by install.sh
TZ="$NB_TIMEZONE"

NB_AUTH_ISSUER=https://$NB_DOMAIN:$NB_EXTERNAL_PORT/realms/$NB_ORG
NB_AUTH_OIDC_CONFIGURATION_ENDPOINT=https://$NB_DOMAIN:$NB_EXTERNAL_PORT/realms/$NB_ORG/.well-known/openid-configuration
NB_AUTH_TOKEN_ENDPOINT=https://$NB_DOMAIN:$NB_EXTERNAL_PORT/realms/$NB_ORG/protocol/openid-connect/token
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

__write_dashboard_env() {
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

__write_turnserver_conf() {
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
user=$(__read_value "$TURN_USER_FILE"):$(__read_value "$TURN_PASS_FILE")
log-file=stdout
EOF
}

__write_management_json() {
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
        "Username": "$(__read_value "$TURN_USER_FILE")",
        "Password": "$(__read_value "$TURN_PASS_FILE")"
      }
    ],
    "CredentialsTTL": "12h",
    "Secret": "$(__read_value "$TURN_PASS_FILE")",
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
  "DataStoreEncryptionKey": "$(__read_value "$DATASTORE_KEY_FILE")",
  "HttpConfig": {
    "Address": "0.0.0.0:8080",
    "AuthIssuer": "$NB_AUTH_ISSUER",
    "AuthAudience": "$NB_AUTH_CLIENT_ID",
    "AuthKeysLocation": "http://$KC_SVC:8080/realms/$NB_ORG/protocol/openid-connect/certs",
    "IdpSignKeyRefreshEnabled": true
  },
  "IdpManagerConfig": {
    "ManagerType": "keycloak",
    "ClientConfig": {
      "Issuer": "$NB_AUTH_ISSUER",
      "TokenEndpoint": "http://$KC_SVC:8080/realms/$NB_ORG/protocol/openid-connect/token",
      "ClientID": "$NB_IDP_MGMT_CLIENT_ID",
      "ClientSecret": "$NB_IDP_MGMT_CLIENT_SECRET",
      "GrantType": "client_credentials"
    },
    "ExtraConfig": {
      "AdminEndpoint": "http://$KC_SVC:8080/admin/realms/$NB_ORG"
    }
  },
  "PKCEAuthorizationFlow": {
    "ProviderConfig": {
      "Audience": "$NB_AUTH_CLIENT_ID",
      "ClientID": "$NB_AUTH_CLIENT_ID",
      "ClientSecret": "",
      "AuthorizationEndpoint": "$NB_AUTH_ISSUER/protocol/openid-connect/auth",
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

__write_compose() {
	rw_opts="$(__bind_rw_opts)"
	ro_opts="$(__bind_ro_opts)"
	cat >"$DC_FILE" <<EOF
# Autogenerated by install.sh — NetBird self-hosted stack
name: netbird
services:
  $KC_DB_SVC:
    image: docker.io/postgres:16-alpine
    restart: unless-stopped
    env_file:
      - $KC_ENV_FILE
    volumes:
      - $KC_DB_DATA:/var/lib/postgresql/data:$rw_opts
    networks: [$NB_DOCKER_NETWORK]
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U \$\$POSTGRES_USER -d \$\$POSTGRES_DB"]
      interval: 10s
      timeout: 5s
      retries: 12
    logging:
      driver: json-file
      options:
        max-size: "10m"
        max-file: "3"

  $KC_SVC:
    image: quay.io/keycloak/keycloak:26.2
    depends_on:
      $KC_DB_SVC:
        condition: service_healthy
    restart: unless-stopped
    env_file:
      - $KC_ENV_FILE
    command: start
    volumes:
      - $KC_DATA:/opt/keycloak/data:$rw_opts
    ports:
      - 127.0.0.1:$NB_KC_BACKEND_PORT:8080
      - 127.0.0.1:$NB_KC_MGMT_PORT:9000
    networks: [$NB_DOCKER_NETWORK]
    healthcheck:
      test: ["CMD-SHELL", "exec 3<>/dev/tcp/localhost/9000 && printf 'GET /health/ready HTTP/1.0\\r\\nHost: localhost\\r\\n\\r\\n' >&3 && grep -q -- '200' <&3"]
      interval: 15s
      timeout: 10s
      retries: 30
      start_period: 300s
    logging:
      driver: json-file
      options:
        max-size: "10m"
        max-file: "3"

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
    logging:
      driver: json-file
      options:
        max-size: "10m"
        max-file: "3"

  $MGMT_SVC:
    image: docker.io/netbirdio/management:latest
    depends_on:
      $KC_DB_SVC:
        condition: service_healthy
      $KC_SVC:
        condition: service_healthy
    restart: unless-stopped
    entrypoint:
      - /go/bin/netbird-mgmt
      - management
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
    logging:
      driver: json-file
      options:
        max-size: "10m"
        max-file: "3"

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
    logging:
      driver: json-file
      options:
        max-size: "10m"
        max-file: "3"

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
    logging:
      driver: json-file
      options:
        max-size: "10m"
        max-file: "3"

networks:
  $NB_DOCKER_NETWORK:
    name: $NB_DOCKER_NETWORK
    driver: bridge
EOF
}

# - - - - - - - - - - - - - - - - - - - - - - - - -
# Write an nginx reverse-proxy vhost for the NetBird stack when the
# system uses /etc/nginx/vhosts.d/. Skipped silently on systems without that
# directory. The file is always regenerated (idempotent).
__write_nginx_vhost() {
	[ -d /etc/nginx/vhosts.d ] || return 0
	vhost_file="/etc/nginx/vhosts.d/$NB_DOMAIN.conf"
	cat >"$vhost_file" <<EOF
# Autogenerated by install.sh — do not edit by hand
# NetBird self-hosted reverse proxy for $NB_DOMAIN

server {
  listen                                    $NB_EXTERNAL_PORT ssl http2;
  listen                                    [::]:$NB_EXTERNAL_PORT ssl http2;
  server_name                               $NB_DOMAIN;
  access_log                                /var/log/nginx/access.$NB_DOMAIN.log;
  error_log                                 /var/log/nginx/error.$NB_DOMAIN.log info;
  keepalive_timeout                         75 75;
  client_max_body_size                      0;
  chunked_transfer_encoding                 on;
  add_header Strict-Transport-Security      "max-age=7200";
  ssl_protocols                             TLSv1.2 TLSv1.3;
  ssl_ciphers                               'EECDH+AESGCM:EDH+AESGCM:AES256+EECDH:AES256+EDH';
  ssl_prefer_server_ciphers                 on;
  ssl_session_cache                         shared:SSL:10m;
  ssl_session_timeout                       1d;
  ssl_certificate                           $NB_SSL_CERT;
  ssl_certificate_key                       $NB_SSL_KEY;

  # NetBird Signal — long-lived peer gRPC connections
  location /signalexchange.SignalExchange {
    grpc_pass                               grpc://127.0.0.1:$NB_SIGNAL_BACKEND_PORT;
    grpc_set_header                         Host               \$host;
    grpc_set_header                         X-Real-IP          \$remote_addr;
    grpc_set_header                         X-Forwarded-For    \$remote_addr;
    grpc_read_timeout                       3600s;
    grpc_send_timeout                       3600s;
    }

  # NetBird Management — gRPC
  location /management.ManagementService {
    grpc_pass                               grpc://127.0.0.1:$NB_MANAGEMENT_HTTP_BACKEND_PORT;
    grpc_set_header                         Host               \$host;
    grpc_set_header                         X-Real-IP          \$remote_addr;
    grpc_set_header                         X-Forwarded-For    \$remote_addr;
    grpc_read_timeout                       3600s;
    grpc_send_timeout                       3600s;
    }

  # NetBird Management REST API
  location /api {
    send_timeout                            3600;
    proxy_connect_timeout                   3600;
    proxy_send_timeout                      3600;
    proxy_read_timeout                      3600;
    proxy_http_version                      1.1;
    proxy_buffering                         off;
    proxy_request_buffering                 off;
    proxy_set_header                        Host               \$host;
    proxy_set_header                        X-Real-IP          \$remote_addr;
    proxy_set_header                        X-Forwarded-Proto  \$scheme;
    proxy_set_header                        X-Forwarded-Scheme \$scheme;
    proxy_set_header                        X-Forwarded-For    \$proxy_add_x_forwarded_for;
    proxy_set_header                        X-Forwarded-Port   \$server_port;
    proxy_pass                              http://127.0.0.1:$NB_MANAGEMENT_HTTP_BACKEND_PORT;
    }

  # Keycloak OIDC, admin UI, and static resources
  location ~ ^/(realms|admin|resources|js)/ {
    send_timeout                            3600;
    proxy_connect_timeout                   3600;
    proxy_send_timeout                      3600;
    proxy_read_timeout                      3600;
    proxy_http_version                      1.1;
    proxy_buffer_size                       128k;
    proxy_buffers                           4 256k;
    proxy_busy_buffers_size                 256k;
    proxy_set_header                        Host               \$host;
    proxy_set_header                        X-Real-IP          \$remote_addr;
    proxy_set_header                        X-Forwarded-Proto  \$scheme;
    proxy_set_header                        X-Forwarded-Scheme \$scheme;
    proxy_set_header                        X-Forwarded-For    \$proxy_add_x_forwarded_for;
    proxy_set_header                        X-Forwarded-Port   \$server_port;
    proxy_redirect                          http:// https://;
    proxy_pass                              http://127.0.0.1:$NB_KC_BACKEND_PORT;
    }

  # NetBird dashboard (catch-all)
  location / {
    send_timeout                            3600;
    proxy_connect_timeout                   3600;
    proxy_send_timeout                      3600;
    proxy_read_timeout                      3600;
    proxy_http_version                      1.1;
    proxy_buffering                         off;
    proxy_request_buffering                 off;
    proxy_set_header                        Host               \$host;
    proxy_set_header                        X-Real-IP          \$remote_addr;
    proxy_set_header                        X-Forwarded-Proto  \$scheme;
    proxy_set_header                        X-Forwarded-Scheme \$scheme;
    proxy_set_header                        X-Forwarded-For    \$proxy_add_x_forwarded_for;
    proxy_set_header                        X-Forwarded-Port   \$server_port;
    proxy_set_header                        Upgrade            \$http_upgrade;
    proxy_set_header                        Connection         \$connection_upgrade;
    proxy_redirect                          http:// https://;
    proxy_pass                              http://127.0.0.1:$NB_DASHBOARD_BACKEND_PORT;
    }
}
EOF
	if __have_cmd nginx; then
		if nginx -t 2>/dev/null; then
			nginx -s reload 2>/dev/null && \
				__say "nginx: vhost written and reloaded -> $vhost_file" || \
				__say "nginx: vhost written but reload failed -> $vhost_file"
		else
			__say "nginx: vhost written but config test failed — check $vhost_file"
			nginx -t 2>&1 | sed 's/^/  /' >&2
		fi
	else
		__say "nginx: vhost written -> $vhost_file (nginx not running)"
	fi
}

# - - - - - - - - - - - - - - - - - - - - - - - - -
# Add the Docker bridge subnet to firewalld's trusted zone so containers
# on the same bridge can reach each other. Firewalld's FORWARD chain
# otherwise rejects intra-bridge traffic (only oifname "eth0" is allowed
# in the public zone). Must run after "docker compose up" creates the network.
__configure_docker_firewalld() {
	__have_cmd firewall-cmd || return 0
	nb_subnet=$(docker network inspect "$NB_DOCKER_NETWORK" \
		--format='{{(index .IPAM.Config 0).Subnet}}' 2>/dev/null) || return 0
	[ -n "$nb_subnet" ] || return 0
	firewall-cmd --quiet --zone=trusted --add-source="$nb_subnet" 2>/dev/null || true
	firewall-cmd --quiet --permanent --zone=trusted --add-source="$nb_subnet" 2>/dev/null || true
	firewall-cmd --quiet --reload 2>/dev/null || true
	__say "Firewall: Docker network subnet $nb_subnet added to trusted zone"
}

# - - - - - - - - - - - - - - - - - - - - - - - - -
# Validation and admin bootstrap
__validate_compose_definition() {
	(
		cd "$NB_COMPOSE"
		set -a
		. "$KC_ENV_FILE"
		. "$NETBIRD_ENV_FILE"
		set +a
		docker compose config >/dev/null
	)
}

__validate_running_services() {
	__say "Waiting for all services to reach running state (up to 5 minutes)..."
	attempt=1
	while [ "$attempt" -le 60 ]; do
		all_running=1
		running_services="$(docker compose -f "$DC_FILE" ps --services --status running 2>/dev/null)"
		for service in "$KC_DB_SVC" "$KC_SVC" "$TURN_SVC" "$MGMT_SVC" "$DASH_SVC" "$SIG_SVC"; do
			if ! printf '%s\n' "$running_services" | grep -qx -- "$service"; then
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
	for service in "$KC_DB_SVC" "$KC_SVC" "$TURN_SVC" "$MGMT_SVC" "$DASH_SVC" "$SIG_SVC"; do
		printf '%s\n' "$running_services" | grep -qx -- "$service" || __die "service did not reach running state: $service"
	done
}

__ensure_admin_user() {
	__say "Keycloak admin credentials:"
	__say "  URL:      https://$NB_DOMAIN:$NB_EXTERNAL_PORT"
	__say "  Username: admin"
	__say "  Password: see $KC_ADMIN_PASS_FILE"
}

# __auto_configure_oidc — uses the Keycloak admin REST API to create the netbird
# realm, PKCE client, and management service account automatically.
# Runs only when netbird.env still contains placeholder credentials.
# On subsequent runs this function is a no-op.
__auto_configure_oidc() {
	# Already configured — nothing to do
	if ! grep -q -- 'replace-me' "$NETBIRD_ENV_FILE" 2>/dev/null; then
		return 0
	fi

	__say "Auto-configuring Keycloak OIDC for NetBird..."

	kc_url="http://127.0.0.1:$NB_KC_BACKEND_PORT"
	kc_admin_pass="$(__read_value "$KC_ADMIN_PASS_FILE")"

	# ------------------------------------------------------------------
	# 1. Obtain admin token from master realm
	# ------------------------------------------------------------------
	token_resp=$(curl -sSf \
		--data-urlencode "grant_type=password" \
		--data-urlencode "client_id=admin-cli" \
		--data-urlencode "username=admin" \
		--data-urlencode "password=$kc_admin_pass" \
		"$kc_url/realms/master/protocol/openid-connect/token") \
		|| __die "OIDC setup: failed to obtain Keycloak admin token"
	admin_token=$(printf '%s' "$token_resp" | python3 -c 'import sys,json; print(json.load(sys.stdin)["access_token"], end="")')
	[ -n "$admin_token" ] || __die "OIDC setup: empty admin token"
	__say "  Keycloak admin token obtained"

	# ------------------------------------------------------------------
	# 2. Create netbird realm
	# ------------------------------------------------------------------
	curl -sSf -X POST \
		-H "Authorization: Bearer $admin_token" \
		-H "Content-Type: application/json" \
		-d "{\"realm\":\"$NB_ORG\",\"enabled\":true,\"displayName\":\"NetBird\",\"registrationAllowed\":true,\"resetPasswordAllowed\":true}" \
		"$kc_url/admin/realms" >/dev/null \
		|| __say "  Note: $NB_ORG realm may already exist, continuing..."
	__say "  Realm '$NB_ORG' ensured"

	# ------------------------------------------------------------------
	# 3. Create PKCE public client (for end users / NetBird CLI / dashboard)
	# ------------------------------------------------------------------
	curl -sSf -X POST \
		-H "Authorization: Bearer $admin_token" \
		-H "Content-Type: application/json" \
		-d "{\"clientId\":\"netbird-client\",\"enabled\":true,\"publicClient\":true,\"standardFlowEnabled\":true,"\
"\"directAccessGrantsEnabled\":false,\"redirectUris\":[\"http://localhost:53000/*\",\"http://localhost:54000/*\",\"https://$NB_DOMAIN/*\"],\"webOrigins\":[\"+\"]}" \
		"$kc_url/admin/realms/$NB_ORG/clients" >/dev/null \
		|| __say "  Note: netbird-client may already exist, continuing..."
	__say "  PKCE client 'netbird-client' ensured"

	# ------------------------------------------------------------------
	# 4. Add audience mapper to netbird-client so access tokens contain
	#    netbird-client in the aud claim (required by NetBird management)
	# ------------------------------------------------------------------
	nb_client_uuid=$(curl -sSf \
		-H "Authorization: Bearer $admin_token" \
		"$kc_url/admin/realms/$NB_ORG/clients?clientId=netbird-client" \
		| python3 -c 'import sys,json; print(json.load(sys.stdin)[0]["id"], end="")')
	[ -n "$nb_client_uuid" ] || __die "OIDC setup: could not find netbird-client UUID"

	# Ensure redirect URIs include the domain even when the client already existed
	curl -sSf -X PUT \
		-H "Authorization: Bearer $admin_token" \
		-H "Content-Type: application/json" \
		-d "{\"clientId\":\"netbird-client\",\"enabled\":true,\"publicClient\":true,\"standardFlowEnabled\":true,"\
"\"directAccessGrantsEnabled\":false,\"redirectUris\":[\"http://localhost:53000/*\",\"http://localhost:54000/*\",\"https://$NB_DOMAIN/*\"],\"webOrigins\":[\"+\"]}" \
		"$kc_url/admin/realms/$NB_ORG/clients/$nb_client_uuid" >/dev/null \
		&& __say "  netbird-client redirect URIs patched (https://$NB_DOMAIN/*)"

	curl -sSf -X POST \
		-H "Authorization: Bearer $admin_token" \
		-H "Content-Type: application/json" \
		-d '{"name":"netbird-audience","protocol":"openid-connect","protocolMapper":"oidc-audience-mapper",'\
'"config":{"id.token.claim":"false","access.token.claim":"true","included.client.audience":"netbird-client"}}' \
		"$kc_url/admin/realms/$NB_ORG/clients/$nb_client_uuid/protocol-mappers/models" >/dev/null \
		|| __say "  Note: audience mapper may already exist, continuing..."
	__say "  Audience mapper added to netbird-client"

	# ------------------------------------------------------------------
	# 5. Create confidential service account client (for management backend)
	# ------------------------------------------------------------------
	curl -sSf -X POST \
		-H "Authorization: Bearer $admin_token" \
		-H "Content-Type: application/json" \
		-d '{"clientId":"netbird-management","enabled":true,"publicClient":false,"serviceAccountsEnabled":true,"standardFlowEnabled":false,"clientAuthenticatorType":"client-secret"}' \
		"$kc_url/admin/realms/$NB_ORG/clients" >/dev/null \
		|| __say "  Note: netbird-management client may already exist, continuing..."
	__say "  Service account client 'netbird-management' ensured"

	# ------------------------------------------------------------------
	# 6. Fetch management client UUID and regenerate secret
	# ------------------------------------------------------------------
	mgmt_uuid=$(curl -sSf \
		-H "Authorization: Bearer $admin_token" \
		"$kc_url/admin/realms/$NB_ORG/clients?clientId=netbird-management" \
		| python3 -c 'import sys,json; print(json.load(sys.stdin)[0]["id"], end="")')
	[ -n "$mgmt_uuid" ] || __die "OIDC setup: could not find netbird-management UUID"

	secret_resp=$(curl -sSf -X POST \
		-H "Authorization: Bearer $admin_token" \
		"$kc_url/admin/realms/$NB_ORG/clients/$mgmt_uuid/client-secret")
	mgmt_secret=$(printf '%s' "$secret_resp" | python3 -c 'import sys,json; print(json.load(sys.stdin)["value"], end="")')
	[ -n "$mgmt_secret" ] || __die "OIDC setup: could not obtain management client secret"
	__say "  Management client secret generated"

	# ------------------------------------------------------------------
	# 7. Grant realm-admin role to the management service account so it
	#    can manage users via the Keycloak admin API
	# ------------------------------------------------------------------
	sa_user_id=$(curl -sSf \
		-H "Authorization: Bearer $admin_token" \
		"$kc_url/admin/realms/$NB_ORG/clients/$mgmt_uuid/service-account-user" \
		| python3 -c 'import sys,json; print(json.load(sys.stdin)["id"], end="")')
	[ -n "$sa_user_id" ] || __die "OIDC setup: could not find service account user ID"

	rm_uuid=$(curl -sSf \
		-H "Authorization: Bearer $admin_token" \
		"$kc_url/admin/realms/$NB_ORG/clients?clientId=realm-management" \
		| python3 -c 'import sys,json; print(json.load(sys.stdin)[0]["id"], end="")')
	[ -n "$rm_uuid" ] || __die "OIDC setup: could not find realm-management client UUID"

	realm_admin_role=$(curl -sSf \
		-H "Authorization: Bearer $admin_token" \
		"$kc_url/admin/realms/$NB_ORG/clients/$rm_uuid/roles/realm-admin")
	[ -n "$realm_admin_role" ] || __die "OIDC setup: could not fetch realm-admin role"

	curl -sSf -X POST \
		-H "Authorization: Bearer $admin_token" \
		-H "Content-Type: application/json" \
		-d "[$realm_admin_role]" \
		"$kc_url/admin/realms/$NB_ORG/users/$sa_user_id/role-mappings/clients/$rm_uuid" >/dev/null \
		|| __say "  Note: realm-admin role may already be assigned, continuing..."
	__say "  realm-admin role assigned to netbird-management service account"

	# ------------------------------------------------------------------
	# 8. Update netbird.env with the real credentials
	# ------------------------------------------------------------------
	sed -i \
		-e "s|^NB_AUTH_CLIENT_ID=.*|NB_AUTH_CLIENT_ID=netbird-client|" \
		-e "s|^NB_AUTH_CLIENT_SECRET=.*|NB_AUTH_CLIENT_SECRET=|" \
		-e "s|^NB_IDP_MGMT_CLIENT_ID=.*|NB_IDP_MGMT_CLIENT_ID=netbird-management|" \
		-e "s|^NB_IDP_MGMT_CLIENT_SECRET=.*|NB_IDP_MGMT_CLIENT_SECRET=$mgmt_secret|" \
		"$NETBIRD_ENV_FILE"
	__say "  Updated $NETBIRD_ENV_FILE with Keycloak credentials"
	__say "OIDC auto-configuration complete."
}

# - - - - - - - - - - - - - - - - - - - - - - - - -
# Main flow
__configure_kernel
__install_docker
__configure_host_integration
__ensure_runtime_secrets

__write_keycloak_env
__write_netbird_env

set -a
. "$KC_ENV_FILE"
. "$NETBIRD_ENV_FILE"
set +a

__write_dashboard_env
__write_turnserver_conf
__write_management_json
__write_compose
__validate_compose_definition

(
	cd "$NB_COMPOSE"
	set -a
	. "$KC_ENV_FILE"
	. "$NETBIRD_ENV_FILE"
	set +a
	docker compose pull
	docker compose up -d
)

__configure_docker_firewalld
__validate_running_services
__wait_for_http "http://127.0.0.1:$NB_KC_MGMT_PORT/health/ready" "Keycloak"
__wait_for_http "http://127.0.0.1:$NB_DASHBOARD_BACKEND_PORT/" "NetBird dashboard"

# Auto-configure Keycloak OIDC on first install (no-op on reruns)
__auto_configure_oidc

# If OIDC was just configured, reload env and rewrite + restart affected services
if ! grep -q -- 'replace-me' "$NETBIRD_ENV_FILE" 2>/dev/null; then
	set -a
	. "$NETBIRD_ENV_FILE"
	set +a
	# Rewrite configs that embed the client IDs
	__write_dashboard_env
	__write_management_json
	(
		cd "$NB_COMPOSE"
		set -a
		. "$KC_ENV_FILE"
		. "$NETBIRD_ENV_FILE"
		set +a
		docker compose up -d --force-recreate "$MGMT_SVC" "$DASH_SVC"
	)
	__say "Waiting for management and dashboard to restart with real OIDC config..."
	attempt=1
	while [ "$attempt" -le 30 ]; do
		running="$(docker compose -f "$DC_FILE" ps --services --status running 2>/dev/null)"
		if printf '%s\n' "$running" | grep -qx -- "$MGMT_SVC" && printf '%s\n' "$running" | grep -qx -- "$DASH_SVC"; then
			break
		fi
		sleep 5
		attempt=$((attempt + 1))
	done
fi

__write_nginx_vhost
__ensure_admin_user

cat <<OUT

================================================================================
NetBird self-hosted stack is up (or updated) at: $NB_ROOT

Host integration:
  - Kernel modules:   $NB_MODULES_FILE
  - sysctl drop-in:   $NB_SYSCTL_FILE
  - Firewalld opened: tcp/$NB_EXTERNAL_PORT, udp/$NB_TURN_PORT, udp/$NB_TURN_MIN_PORT-$NB_TURN_MAX_PORT
  - SELinux bind relabeling: $(if __selinux_enabled; then printf 'enabled'; else printf 'not required'; fi)

Local reverse-proxy backends:
  - Dashboard root                          -> http://127.0.0.1:$NB_DASHBOARD_BACKEND_PORT
  - Management REST / websocket proxy       -> http://127.0.0.1:$NB_MANAGEMENT_HTTP_BACKEND_PORT
  - Keycloak OIDC / UI                      -> http://127.0.0.1:$NB_KC_BACKEND_PORT
  - Signal                                  -> http://127.0.0.1:$NB_SIGNAL_BACKEND_PORT
  - TURN                                    -> udp/$NB_TURN_PORT and udp/$NB_TURN_MIN_PORT-$NB_TURN_MAX_PORT

Keycloak admin:
  - URL:      https://$NB_DOMAIN:$NB_EXTERNAL_PORT
  - Username: admin
  - Password: see $KC_ADMIN_PASS_FILE

Important config files:
  - Keycloak env:        $KC_ENV_FILE
  - NetBird env:         $NETBIRD_ENV_FILE
  - Dashboard env:       $DASHBOARD_ENV_FILE
  - Management config:   $MGMT_JSON_FILE
  - Coturn config:       $TURN_CONF_FILE

This script is idempotent for reruns: generated secrets, database credentials,
and datastore encryption keys are preserved unless you replace the files
under $NB_SECRETS yourself.
================================================================================
OUT

exit 0
# ex: ts=2 sw=2 et filetype=sh
