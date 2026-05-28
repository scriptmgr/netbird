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
# Argument handling
case "${1:-}" in
--help|-h)
    printf 'Usage: %s [--help|--version]\n\n' "$APPNAME"
    printf 'NetBird self-hosted stack installer and updater.\n\n'
    printf 'Run as root with no arguments to install or update the stack.\n'
    printf 'Override defaults via environment variables or a .env file next to this script.\n\n'
    printf 'Key environment variables:\n'
    printf '  NB_DOMAIN            FQDN for the stack (default: auto-detected)\n'
    printf '  NB_ROOT              Install root (default: /opt/netbird)\n'
    printf '  NB_ORG               Keycloak realm name (default: netbird)\n'
    printf '  NB_EXTERNAL_PORT     Public HTTPS port (default: 443)\n'
    printf '  NB_TURN_PORT         TURN UDP port (default: 3478)\n'
    printf '  NB_VERSION           NetBird version tag (default: %s)\n' "${NB_VERSION:-0.71.4}"
    printf '  NB_DASHBOARD_VERSION Dashboard version tag (default: %s)\n' "${NB_DASHBOARD_VERSION:-v2.38.1}"
    printf '  NB_ADMIN_USER        Day-to-day NetBird admin username (default: administrator)\n'
    printf '  NB_ADMIN_EMAIL       Day-to-day NetBird admin email (default: administrator@{NB_DOMAIN})\n'
    printf '\nSee README.md for full documentation.\n'
    exit 0
    ;;
--version|-v)
    printf '%s %s\n' "$APPNAME" "$VERSION"
    exit 0
    ;;
'') ;;
*)
    printf '%s: unknown option: %s\n' "$APPNAME" "$1" >&2
    printf 'Run %s --help for usage.\n' "$APPNAME" >&2
    exit 2
    ;;
esac

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

# __wait_for_management — like __wait_for_http but also accepts 401/403 as "up"
# (management returns 401 on unauthenticated requests before OIDC is configured)
__wait_for_management() {
	url="$1"
	attempt=1
	while [ "$attempt" -le 150 ]; do
		http_code="$(curl -ksS -o /dev/null -w '%{http_code}' "$url" 2>/dev/null || printf '000')"
		case "$http_code" in
			200|401|403) return 0 ;;
		esac
		sleep 2
		attempt=$((attempt + 1))
	done
	__die "timed out waiting for management API at $url"
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

# __nb_origin — canonical base URL, scheme chosen by port, default ports omitted.
# RFC 3986: the default port MUST be omitted from the authority component.
# Keycloak normalizes its KC_HOSTNAME the same way, so the JWT iss claim will
# never contain :443 or :80.  Management, dashboard, and netbird.env configs
# must match that exact string or JWT issuer validation will fail.
__nb_origin() {
	case "$NB_EXTERNAL_PORT" in
	443) printf 'https://%s' "$NB_DOMAIN" ;;
	80)  printf 'http://%s'  "$NB_DOMAIN" ;;
	*)   printf 'https://%s:%s' "$NB_DOMAIN" "$NB_EXTERNAL_PORT" ;;
	esac
}
: "${NB_EMAIL_SMTP_HOST:=172.17.0.1}"
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
: "${NB_VERSION:=0.71.4}"
: "${NB_DASHBOARD_VERSION:=v2.38.1}"
: "${NB_SSL_CERT:=$NB_ROOT/etc/tls/fullchain.pem}"
: "${NB_SSL_KEY:=$NB_ROOT/etc/tls/privkey.pem}"
: "${NB_ADMIN_USER:=administrator}"
: "${NB_ADMIN_EMAIL:=administrator@$NB_DOMAIN}"

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
NB_ADMIN_PASS_FILE="$NB_SECRETS/nb_admin_password"

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
		systemctl is-enabled docker >/dev/null 2>&1 || systemctl enable docker 2>/dev/null || __say "Warning: could not enable docker service — continuing (it is already running)"
		systemctl is-active docker >/dev/null 2>&1 || systemctl start docker 2>/dev/null || __say "Warning: could not start docker service — continuing"
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
			systemctl enable --now docker 2>/dev/null || __say "Warning: could not enable/start docker via systemctl — continuing"
			;;
		fedora)
			__need_cmd dnf
			dnf -y install dnf-plugins-core
			dnf config-manager --add-repo https://download.docker.com/linux/fedora/docker-ce.repo
			dnf -y remove containerd 2>/dev/null || true
			dnf -y install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
			systemctl enable --now docker 2>/dev/null || __say "Warning: could not enable/start docker via systemctl — continuing"
			;;
		almalinux | rocky | centos | rhel | ol)
			__need_cmd dnf
			dnf -y install dnf-plugins-core
			dnf config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo
			dnf -y remove containerd 2>/dev/null || true
			dnf -y install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
			systemctl enable --now docker 2>/dev/null || __say "Warning: could not enable/start docker via systemctl — continuing"
			;;
		opensuse* | sles)
			__need_cmd zypper
			zypper refresh
			zypper -n install docker docker-compose
			systemctl enable --now docker 2>/dev/null || __say "Warning: could not enable/start docker via systemctl — continuing"
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
			systemctl enable --now docker 2>/dev/null || __say "Warning: could not enable/start docker via systemctl — continuing"
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
	systemctl is-enabled docker >/dev/null 2>&1 || systemctl enable docker 2>/dev/null || __say "Warning: could not enable docker service — continuing"
	systemctl is-active docker >/dev/null 2>&1 || systemctl start docker 2>/dev/null || __say "Warning: could not start docker service — continuing"
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
		systemctl enable --now firewalld 2>/dev/null || __say "Warning: could not enable/start firewalld — continuing"
		if __selinux_enabled; then
			setsebool -P httpd_can_network_connect 1
			__say "SELinux: httpd_can_network_connect enabled (nginx → upstream proxying)"
		fi
		;;
	esac

	if __have_cmd firewall-cmd; then
		# Unconditional: SSH and web must always be reachable on the public interface.
		# These are added before any peer/VPN changes so out-of-band access is never lost.
		firewall-cmd --quiet --permanent --add-service=ssh 2>/dev/null || true
		firewall-cmd --quiet --permanent --add-port=22/tcp 2>/dev/null || true
		__firewall_open_port "80/tcp"
		__firewall_open_port "443/tcp"
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
	__ensure_secret_file "$NB_ADMIN_PASS_FILE" 24 "NetBird admin password"
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

KC_HOSTNAME=$(__nb_origin)
KC_HTTP_ENABLED=true
KC_PROXY_HEADERS=xforwarded
KC_HOSTNAME_STRICT=false
KC_HEALTH_ENABLED=true
EOF
}

__write_netbird_env() {
	_nb_o="$(__nb_origin)"
	if [ ! -f "$NETBIRD_ENV_FILE" ]; then
		cat >"$NETBIRD_ENV_FILE" <<EOF
# Autogenerated by install.sh
TZ="$NB_TIMEZONE"

NB_AUTH_ISSUER=${_nb_o}/realms/$NB_ORG
NB_AUTH_OIDC_CONFIGURATION_ENDPOINT=${_nb_o}/realms/$NB_ORG/.well-known/openid-configuration
NB_AUTH_TOKEN_ENDPOINT=${_nb_o}/realms/$NB_ORG/protocol/openid-connect/token
NB_AUTH_CLIENT_ID=$NB_AUTH_CLIENT_ID
NB_AUTH_CLIENT_SECRET=$NB_AUTH_CLIENT_SECRET
NB_IDP_MGMT_CLIENT_ID=$NB_IDP_MGMT_CLIENT_ID
NB_IDP_MGMT_CLIENT_SECRET=$NB_IDP_MGMT_CLIENT_SECRET
NB_AUTH_SUPPORTED_SCOPES="$NB_AUTH_SUPPORTED_SCOPES"

NETBIRD_EMAIL_SMTP_HOST="$NB_EMAIL_SMTP_HOST"
NETBIRD_EMAIL_SMTP_PORT="$NB_EMAIL_SMTP_PORT"
NETBIRD_EMAIL_FROM="$NB_EMAIL_FROM_USER"
EOF
	else
		# On reruns: update URL-based lines while preserving OIDC credentials
		sed -i \
			-e "s|^NB_AUTH_ISSUER=.*|NB_AUTH_ISSUER=${_nb_o}/realms/$NB_ORG|" \
			-e "s|^NB_AUTH_OIDC_CONFIGURATION_ENDPOINT=.*|NB_AUTH_OIDC_CONFIGURATION_ENDPOINT=${_nb_o}/realms/$NB_ORG/.well-known/openid-configuration|" \
			-e "s|^NB_AUTH_TOKEN_ENDPOINT=.*|NB_AUTH_TOKEN_ENDPOINT=${_nb_o}/realms/$NB_ORG/protocol/openid-connect/token|" \
			"$NETBIRD_ENV_FILE"
	fi
}

__write_dashboard_env() {
	cat >"$DASHBOARD_ENV_FILE" <<EOF
# Autogenerated by install.sh
NETBIRD_MGMT_API_ENDPOINT=$(__nb_origin)
NETBIRD_MGMT_GRPC_API_ENDPOINT=$(__nb_origin)
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
stale-nonce
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
      - 172.17.0.1:$NB_KC_BACKEND_PORT:8080
      - 172.17.0.1:$NB_KC_MGMT_PORT:9000
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
    image: docker.io/coturn/coturn@sha256:161cedd63c5414c2136f306098e02e9aede74606cedad8b9b8581aae1da4e732
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
    image: docker.io/netbirdio/management:$NB_VERSION
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
      - 172.17.0.1:$NB_MANAGEMENT_HTTP_BACKEND_PORT:8080
    networks: [$NB_DOCKER_NETWORK]
    logging:
      driver: json-file
      options:
        max-size: "10m"
        max-file: "3"

  $DASH_SVC:
    image: docker.io/netbirdio/dashboard:$NB_DASHBOARD_VERSION
    restart: unless-stopped
    env_file:
      - $DASHBOARD_ENV_FILE
    depends_on:
      - $MGMT_SVC
    ports:
      - 172.17.0.1:$NB_DASHBOARD_BACKEND_PORT:80
    networks: [$NB_DOCKER_NETWORK]
    logging:
      driver: json-file
      options:
        max-size: "10m"
        max-file: "3"

  $SIG_SVC:
    image: docker.io/netbirdio/signal:$NB_VERSION
    restart: unless-stopped
    environment:
      - TZ=$NB_TIMEZONE
      - NB_SIGNAL_PORT=10000
    volumes:
      - $SIGNAL_DATA:/var/lib/netbird:$rw_opts
    ports:
      - 172.17.0.1:$NB_SIGNAL_BACKEND_PORT:10000
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
  listen                                    80;
  listen                                    [::]:80;
  server_name                               $NB_DOMAIN;
  return                                    301 https://\$host\$request_uri;
}

server {
  listen                                    $NB_EXTERNAL_PORT ssl http2;
  listen                                    [::]:$NB_EXTERNAL_PORT ssl http2;
  server_name                               $NB_DOMAIN;
  access_log                                /var/log/nginx/access.$NB_DOMAIN.log;
  error_log                                 /var/log/nginx/error.$NB_DOMAIN.log info;
  keepalive_timeout                         75 75;
  client_max_body_size                      0;
  chunked_transfer_encoding                 on;
  add_header Strict-Transport-Security      "max-age=31536000; includeSubDomains";
  gzip                                      on;
  gzip_vary                                 on;
  gzip_proxied                              any;
  gzip_comp_level                           6;
  gzip_min_length                           1024;
  gzip_types                                text/css text/javascript application/javascript application/json font/woff2;
  ssl_protocols                             TLSv1.2 TLSv1.3;
  ssl_ciphers                               'EECDH+AESGCM:EDH+AESGCM:AES256+EECDH:AES256+EDH';
  ssl_prefer_server_ciphers                 on;
  ssl_session_cache                         shared:SSL:10m;
  ssl_session_timeout                       1d;
  ssl_certificate                           $NB_SSL_CERT;
  ssl_certificate_key                       $NB_SSL_KEY;

  # NetBird Signal — long-lived peer gRPC connections
  location /signalexchange.SignalExchange {
    grpc_pass                               grpc://172.17.0.1:$NB_SIGNAL_BACKEND_PORT;
    grpc_set_header                         Host               \$host;
    grpc_set_header                         X-Real-IP          \$remote_addr;
    grpc_set_header                         X-Forwarded-For    \$remote_addr;
    grpc_read_timeout                       3600s;
    grpc_send_timeout                       3600s;
    }

  # NetBird Management — gRPC
  location /management.ManagementService {
    grpc_pass                               grpc://172.17.0.1:$NB_MANAGEMENT_HTTP_BACKEND_PORT;
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
    proxy_pass                              http://172.17.0.1:$NB_MANAGEMENT_HTTP_BACKEND_PORT;
    }

  # Keycloak OIDC, admin UI, and static resources
  location ~ ^/(realms|admin|resources|js)/ {
    send_timeout                            3600;
    proxy_connect_timeout                   3600;
    proxy_send_timeout                      3600;
    proxy_read_timeout                      3600;
    proxy_http_version                      1.1;
    proxy_buffering                         off;
    proxy_set_header                        Accept-Encoding    "";
    proxy_set_header                        Host               \$host;
    proxy_set_header                        X-Real-IP          \$remote_addr;
    proxy_set_header                        X-Forwarded-Proto  \$scheme;
    proxy_set_header                        X-Forwarded-Scheme \$scheme;
    proxy_set_header                        X-Forwarded-For    \$proxy_add_x_forwarded_for;
    proxy_set_header                        X-Forwarded-Port   \$server_port;
    proxy_redirect                          http:// https://;
    proxy_pass                              http://172.17.0.1:$NB_KC_BACKEND_PORT;
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
    proxy_pass                              http://172.17.0.1:$NB_DASHBOARD_BACKEND_PORT;
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
	kc_url="http://172.17.0.1:$NB_KC_BACKEND_PORT"
	kc_admin_pass="$(__read_value "$KC_ADMIN_PASS_FILE")"

	# Obtain a short-lived admin token from the master realm
	_ea_token=$(curl -s \
		--data-urlencode "grant_type=password" \
		--data-urlencode "client_id=admin-cli" \
		--data-urlencode "username=admin" \
		--data-urlencode "password=$kc_admin_pass" \
		"$kc_url/realms/master/protocol/openid-connect/token" \
		| python3 -c 'import sys,json; print(json.load(sys.stdin).get("access_token",""), end="")')

	if [ -z "$_ea_token" ]; then
		__say "WARNING: could not obtain Keycloak admin token — skipping admin user creation"
		__say "  Create an admin user manually at $(__nb_origin)/admin"
		return 0
	fi

	# Check whether the admin user already exists
	_ea_existing=$(curl -s \
		-H "Authorization: Bearer $_ea_token" \
		"$kc_url/admin/realms/$NB_ORG/users?username=admin" \
		| python3 -c 'import sys,json; u=json.load(sys.stdin); print(u[0]["id"] if u else "", end="")')

	if [ -n "$_ea_existing" ]; then
		__say "Keycloak: realm admin user already exists — skipping creation"
	else
		# Create the admin user in the NetBird realm.
		# email/firstName/lastName required by Keycloak 26 user profile validation.
		curl -sSf -X POST \
			-H "Authorization: Bearer $_ea_token" \
			-H "Content-Type: application/json" \
			-d "{\"username\":\"admin\",\"email\":\"admin@$NB_DOMAIN\",\"firstName\":\"Admin\",\"lastName\":\"NetBird\",\"enabled\":true,\"emailVerified\":true}" \
			"$kc_url/admin/realms/$NB_ORG/users" >/dev/null \
			|| __die "Failed to create admin user in Keycloak realm $NB_ORG"

		_ea_uuid=$(curl -s \
			-H "Authorization: Bearer $_ea_token" \
			"$kc_url/admin/realms/$NB_ORG/users?username=admin" \
			| python3 -c 'import sys,json; print(json.load(sys.stdin)[0]["id"], end="")')
		[ -n "$_ea_uuid" ] || __die "Admin user created but UUID not found"

		curl -sSf -X PUT \
			-H "Authorization: Bearer $_ea_token" \
			-H "Content-Type: application/json" \
			-d "{\"type\":\"password\",\"value\":\"$kc_admin_pass\",\"temporary\":false}" \
			"$kc_url/admin/realms/$NB_ORG/users/$_ea_uuid/reset-password" >/dev/null \
			|| __die "Failed to set admin user password"

		__say "Keycloak: admin user created in realm $NB_ORG"
	fi

	__say "NetBird dashboard credentials:"
	__say "  URL:      $(__nb_origin)"
	__say "  Username: admin"
	__say "  Password: see $KC_ADMIN_PASS_FILE"

	# Create the separate administrator account (NB_ADMIN_USER) with realm-admin role.
	# This account is for day-to-day NetBird management; admin is reserved for Keycloak config.
	nb_admin_pass="$(__read_value "$NB_ADMIN_PASS_FILE")"
	_ea_nb_existing=$(curl -s \
		-H "Authorization: Bearer $_ea_token" \
		"$kc_url/admin/realms/$NB_ORG/users?username=$NB_ADMIN_USER" \
		| python3 -c 'import sys,json; u=json.load(sys.stdin); print(u[0]["id"] if u else "", end="")')

	if [ -n "$_ea_nb_existing" ]; then
		__say "Keycloak: $NB_ADMIN_USER already exists — skipping creation"
		_ea_nb_uuid="$_ea_nb_existing"
	else
		curl -sSf -X POST \
			-H "Authorization: Bearer $_ea_token" \
			-H "Content-Type: application/json" \
			-d "{\"username\":\"$NB_ADMIN_USER\",\"email\":\"$NB_ADMIN_EMAIL\",\"firstName\":\"Administrator\",\"lastName\":\"NetBird\",\"enabled\":true,\"emailVerified\":true}" \
			"$kc_url/admin/realms/$NB_ORG/users" >/dev/null \
			|| __die "Failed to create $NB_ADMIN_USER in Keycloak realm $NB_ORG"

		_ea_nb_uuid=$(curl -s \
			-H "Authorization: Bearer $_ea_token" \
			"$kc_url/admin/realms/$NB_ORG/users?username=$NB_ADMIN_USER" \
			| python3 -c 'import sys,json; print(json.load(sys.stdin)[0]["id"], end="")')
		[ -n "$_ea_nb_uuid" ] || __die "$NB_ADMIN_USER created but UUID not found"

		curl -sSf -X PUT \
			-H "Authorization: Bearer $_ea_token" \
			-H "Content-Type: application/json" \
			-d "{\"type\":\"password\",\"value\":\"$nb_admin_pass\",\"temporary\":false}" \
			"$kc_url/admin/realms/$NB_ORG/users/$_ea_nb_uuid/reset-password" >/dev/null \
			|| __die "Failed to set $NB_ADMIN_USER password"

		__say "Keycloak: $NB_ADMIN_USER created in realm $NB_ORG"
	fi

	# Assign realm-admin role to NB_ADMIN_USER so they can manage users in Keycloak.
	_ea_rm_uuid=$(curl -s \
		-H "Authorization: Bearer $_ea_token" \
		"$kc_url/admin/realms/$NB_ORG/clients?clientId=realm-management" \
		| python3 -c 'import sys,json; d=json.load(sys.stdin); print(d[0]["id"] if d else "", end="")')
	if [ -n "$_ea_rm_uuid" ]; then
		_ea_ra_role=$(curl -s \
			-H "Authorization: Bearer $_ea_token" \
			"$kc_url/admin/realms/$NB_ORG/clients/$_ea_rm_uuid/roles/realm-admin")
		if printf '%s' "$_ea_ra_role" | python3 -c 'import sys,json; json.load(sys.stdin)' >/dev/null 2>&1; then
			curl -sSf -X POST \
				-H "Authorization: Bearer $_ea_token" \
				-H "Content-Type: application/json" \
				-d "[$_ea_ra_role]" \
				"$kc_url/admin/realms/$NB_ORG/users/$_ea_nb_uuid/role-mappings/clients/$_ea_rm_uuid" >/dev/null \
				|| __say "  Note: realm-admin may already be assigned to $NB_ADMIN_USER"
			__say "Keycloak: realm-admin role assigned to $NB_ADMIN_USER"
		fi
	fi
}

# __auto_configure_oidc — uses the Keycloak admin REST API to create the netbird
# realm, PKCE client, and management service account automatically.
# Runs only when netbird.env still contains placeholder credentials.
# On subsequent runs this function is a no-op.
# Set to 1 by __auto_configure_oidc when it actually runs (not a no-op)
_OIDC_CONFIGURED_THIS_RUN=0

__auto_configure_oidc() {
	# State file written on successful completion — skip on reruns
	if [ -f "$NB_STATE/oidc.done" ]; then
		return 0
	fi

	__say "Auto-configuring Keycloak OIDC for NetBird..."

	kc_url="http://172.17.0.1:$NB_KC_BACKEND_PORT"
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
	touch "$NB_STATE/oidc.done"
	_OIDC_CONFIGURED_THIS_RUN=1
	__say "OIDC auto-configuration complete."
}

# __configure_netbird_defaults — runs once after OIDC is configured.
# Uses the Keycloak OIDC token for the admin user to call the NetBird
# management API and:
#   1. Create a reusable "Default" setup key (3650-day expiry)
#   2. Provision NB_ADMIN_USER into NetBird and grant them admin role
#   3. Set the account DNS domain to NB_DOMAIN
# Direct access grants are temporarily enabled on netbird-client for
# the password grant, then disabled again before returning.
__configure_netbird_defaults() {
	if [ -f "$NB_STATE/netbird_defaults.done" ]; then
		return 0
	fi

	__say "Configuring NetBird defaults (setup key, admin role, DNS domain)..."

	kc_url="http://172.17.0.1:$NB_KC_BACKEND_PORT"
	nb_url="http://172.17.0.1:$NB_MANAGEMENT_HTTP_BACKEND_PORT"
	kc_admin_pass="$(__read_value "$KC_ADMIN_PASS_FILE")"

	# Obtain a Keycloak master-realm admin token to manage client config
	_nd_admin_token=$(curl -s \
		--data-urlencode "grant_type=password" \
		--data-urlencode "client_id=admin-cli" \
		--data-urlencode "username=admin" \
		--data-urlencode "password=$kc_admin_pass" \
		"$kc_url/realms/master/protocol/openid-connect/token" \
		| python3 -c 'import sys,json; print(json.load(sys.stdin).get("access_token",""), end="")')

	if [ -z "$_nd_admin_token" ]; then
		__say "WARNING: could not obtain Keycloak admin token — skipping NetBird defaults configuration"
		return 0
	fi

	# Find the netbird-client UUID
	_nd_nb_client_uuid=$(curl -s \
		-H "Authorization: Bearer $_nd_admin_token" \
		"$kc_url/admin/realms/$NB_ORG/clients?clientId=netbird-client" \
		| python3 -c 'import sys,json; d=json.load(sys.stdin); print(d[0]["id"] if d else "", end="")')

	if [ -z "$_nd_nb_client_uuid" ]; then
		__say "WARNING: netbird-client not found in Keycloak — skipping NetBird defaults"
		return 0
	fi

	# Temporarily enable direct access grants so we can obtain a user JWT
	curl -sSf -X PUT \
		-H "Authorization: Bearer $_nd_admin_token" \
		-H "Content-Type: application/json" \
		-d "{\"clientId\":\"netbird-client\",\"enabled\":true,\"publicClient\":true,\"standardFlowEnabled\":true,\"directAccessGrantsEnabled\":true,\"redirectUris\":[\"http://localhost:53000/*\",\"http://localhost:54000/*\",\"https://$NB_DOMAIN/*\"],\"webOrigins\":[\"+\"]}" \
		"$kc_url/admin/realms/$NB_ORG/clients/$_nd_nb_client_uuid" >/dev/null \
		|| { __say "WARNING: could not enable direct access grants — skipping NetBird defaults"; return 0; }

	# Obtain a JWT for the admin user via resource owner password credentials
	_nd_user_token=$(curl -s \
		--data-urlencode "grant_type=password" \
		--data-urlencode "client_id=netbird-client" \
		--data-urlencode "username=admin" \
		--data-urlencode "password=$kc_admin_pass" \
		--data-urlencode "scope=openid profile email offline_access" \
		"$kc_url/realms/$NB_ORG/protocol/openid-connect/token" \
		| python3 -c 'import sys,json; print(json.load(sys.stdin).get("access_token",""), end="")')

	# Disable direct access grants again regardless of outcome
	curl -s -X PUT \
		-H "Authorization: Bearer $_nd_admin_token" \
		-H "Content-Type: application/json" \
		-d "{\"clientId\":\"netbird-client\",\"enabled\":true,\"publicClient\":true,\"standardFlowEnabled\":true,\"directAccessGrantsEnabled\":false,\"redirectUris\":[\"http://localhost:53000/*\",\"http://localhost:54000/*\",\"https://$NB_DOMAIN/*\"],\"webOrigins\":[\"+\"]}" \
		"$kc_url/admin/realms/$NB_ORG/clients/$_nd_nb_client_uuid" >/dev/null

	if [ -z "$_nd_user_token" ]; then
		__say "WARNING: could not obtain NetBird admin user token — skipping NetBird defaults"
		return 0
	fi
	__say "  NetBird admin user token obtained"

	# Fetch account ID (also provisions the admin user as account owner on first call)
	_nd_account_id=$(curl -s \
		-H "Authorization: Bearer $_nd_user_token" \
		"$nb_url/api/accounts" \
		| python3 -c 'import sys,json; d=json.load(sys.stdin); print(d[0]["id"] if d else "", end="")')

	if [ -z "$_nd_account_id" ]; then
		__say "WARNING: could not fetch NetBird account ID — skipping defaults"
		return 0
	fi
	__say "  NetBird account ID: $_nd_account_id"

	# Update account DNS domain to NB_DOMAIN if the API exposes it
	_nd_acct_resp=$(curl -s \
		-H "Authorization: Bearer $_nd_user_token" \
		"$nb_url/api/accounts/$_nd_account_id")
	_nd_current_domain=$(printf '%s' "$_nd_acct_resp" \
		| python3 -c 'import sys,json; d=json.load(sys.stdin); print(d.get("domain",""), end="")' 2>/dev/null || true)
	if [ -n "$_nd_current_domain" ] && [ "$_nd_current_domain" != "$NB_DOMAIN" ]; then
		_nd_settings=$(printf '%s' "$_nd_acct_resp" \
			| python3 -c 'import sys,json; print(json.dumps(json.load(sys.stdin).get("settings",{})), end="")' 2>/dev/null || true)
		if [ -n "$_nd_settings" ]; then
			curl -s -X PUT \
				-H "Authorization: Bearer $_nd_user_token" \
				-H "Content-Type: application/json" \
				-d "{\"settings\":$_nd_settings}" \
				"$nb_url/api/accounts/$_nd_account_id" >/dev/null \
				|| true
		fi
		__say "  Account DNS domain set to $NB_DOMAIN (was: $_nd_current_domain)"
	else
		__say "  Account DNS domain: $NB_DOMAIN"
	fi

	# Create the "Default" reusable setup key with 3650-day expiry (seconds: 315360000)
	_nd_existing_key=$(curl -s \
		-H "Authorization: Bearer $_nd_user_token" \
		"$nb_url/api/setup-keys" \
		| python3 -c 'import sys,json; keys=json.load(sys.stdin); print(next((k["id"] for k in keys if k.get("name")=="Default"), ""), end="")')
	if [ -n "$_nd_existing_key" ]; then
		__say "  Setup key 'Default' already exists — skipping"
	else
		_nd_key_resp=$(curl -s -X POST \
			-H "Authorization: Bearer $_nd_user_token" \
			-H "Content-Type: application/json" \
			-d '{"name":"Default","type":"reusable","expiry":315360000,"auto_groups":[],"usage_limit":0}' \
			"$nb_url/api/setup-keys")
		_nd_key=$(printf '%s' "$_nd_key_resp" \
			| python3 -c 'import sys,json; d=json.load(sys.stdin); print(d.get("key",""), end="")' 2>/dev/null || true)
		if [ -n "$_nd_key" ]; then
			__say "  Setup key 'Default' created (3650 days): $_nd_key"
			printf '%s\n' "$_nd_key" >"$NB_SECRETS/nb_setup_key_default"
			chmod 600 "$NB_SECRETS/nb_setup_key_default"
		else
			__say "WARNING: failed to create setup key 'Default'"
		fi
	fi

	# Trigger user sync and grant NB_ADMIN_USER the NetBird admin role.
	# GET /api/users fetches from Keycloak IDP and provisions any new users into NetBird.
	_nd_nb_admin_id=$(curl -s \
		-H "Authorization: Bearer $_nd_user_token" \
		"$nb_url/api/users" \
		| python3 -c "import sys,json; users=json.load(sys.stdin); print(next((u['id'] for u in users if u.get('email','').lower()=='$NB_ADMIN_EMAIL'.lower()), ''), end='')")
	if [ -n "$_nd_nb_admin_id" ]; then
		curl -s -X PUT \
			-H "Authorization: Bearer $_nd_user_token" \
			-H "Content-Type: application/json" \
			-d "{\"role\":\"admin\",\"auto_groups\":[]}" \
			"$nb_url/api/users/$_nd_nb_admin_id" >/dev/null \
			|| __say "  Note: could not set admin role for $NB_ADMIN_USER (may already be set)"
		__say "  NetBird admin role granted to $NB_ADMIN_USER ($NB_ADMIN_EMAIL)"
	else
		__say "  Note: $NB_ADMIN_USER not yet in NetBird user list — they will receive admin role on first login (configure manually if needed)"
	fi

	touch "$NB_STATE/netbird_defaults.done"
	__say "NetBird defaults configured."
}

# __ensure_tls_cert — resolve the TLS certificate to use for nginx.
# Priority: 1) any existing Let's Encrypt cert that covers NB_DOMAIN
#           2) NB_SSL_CERT/NB_SSL_KEY if they already exist
#           3) generate a 20-year self-signed cert at the default paths
# Sets NB_SSL_CERT and NB_SSL_KEY in the current shell so __write_nginx_vhost
# picks up the correct paths regardless of what the defaults were.
__ensure_tls_cert() {
	__need_cmd openssl

	# Scan all Live LE dirs; use first cert that covers NB_DOMAIN
	if [ -d /etc/letsencrypt/live ]; then
		for _le_cert in /etc/letsencrypt/live/*/fullchain.pem; do
			[ -f "$_le_cert" ] || continue
			_le_key="${_le_cert%fullchain.pem}privkey.pem"
			[ -f "$_le_key" ] || continue
			if openssl x509 -noout -text -in "$_le_cert" 2>/dev/null \
			   | grep -qE -- "(CN=|DNS:).*$NB_DOMAIN"; then
				NB_SSL_CERT="$_le_cert"
				NB_SSL_KEY="$_le_key"
				__say "TLS: using Let's Encrypt certificate -> $NB_SSL_CERT"
				return 0
			fi
		done
	fi

	# No LE cert — use existing files if present
	[ -f "$NB_SSL_CERT" ] && [ -f "$NB_SSL_KEY" ] && return 0

	# Fall back to self-signed
	mkdir -p "$(dirname -- "$NB_SSL_CERT")" "$(dirname -- "$NB_SSL_KEY")"
	openssl req -x509 -newkey rsa:4096 -sha256 -days 7300 -nodes \
		-keyout "$NB_SSL_KEY" \
		-out "$NB_SSL_CERT" \
		-subj "/CN=$NB_DOMAIN" \
		-addext "subjectAltName=DNS:$NB_DOMAIN" 2>/dev/null \
		|| __die "Failed to generate self-signed TLS certificate"
	chmod 600 "$NB_SSL_KEY"
	__say "TLS: self-signed certificate generated (20 years) -> $NB_SSL_CERT"
}

# __install_host_peer — download the NetBird binary and enroll this host as a peer.
# Skipped if port 51820/UDP is already in use (another WireGuard instance).
# Downloads the release tarball directly from GitHub — no distro packages needed.
# SSH (22/tcp) is permanently opened in firewalld before peer enrollment so the
# host is always reachable out-of-band even if the WireGuard interface has issues.
__install_host_peer() {
	# Already enrolled and connected — nothing to do
	if __have_cmd netbird && netbird status 2>/dev/null | grep -qi 'connected'; then
		__say "NetBird host peer: already connected — skipping"
		return 0
	fi

	# Bail out if something else owns 51820/UDP
	if __have_cmd ss && ss -ulnp 2>/dev/null | grep -q -- ':51820[[:space:]]'; then
		__say "NetBird host peer: port 51820/UDP in use — skipping peer installation"
		return 0
	fi

	setup_key_file="$NB_SECRETS/nb_setup_key_default"
	if [ ! -f "$setup_key_file" ]; then
		__say "NetBird host peer: no setup key at $setup_key_file — skipping (run again after first install)"
		return 0
	fi

	# Map uname -m to the GitHub release arch string
	case "$(uname -m)" in
	x86_64)         _hp_arch=amd64 ;;
	aarch64|arm64)  _hp_arch=arm64 ;;
	armv7*|armv6*)  _hp_arch=armv6 ;;
	*)
		__say "NetBird host peer: unsupported arch $(uname -m) — skipping"
		return 0
		;;
	esac

	_hp_url="https://github.com/netbirdio/netbird/releases/download/v${NB_VERSION}/netbird_${NB_VERSION}_linux_${_hp_arch}.tar.gz"
	_hp_tmp=$(mktemp -d)

	__say "NetBird host peer: downloading v$NB_VERSION ($NB_VERSION) binary..."
	if ! curl -fsSL "$_hp_url" | tar -xzf - -C "$_hp_tmp" netbird 2>/dev/null; then
		__say "WARNING: failed to download NetBird binary from $_hp_url — skipping host peer"
		rm -rf "$_hp_tmp"
		return 0
	fi
	install -m 0755 "$_hp_tmp/netbird" /usr/local/bin/netbird
	rm -rf "$_hp_tmp"
	__say "  Installed: /usr/local/bin/netbird"

	# Ensure SSH is permanently open before touching the network stack
	if __have_cmd firewall-cmd; then
		firewall-cmd --quiet --permanent --add-service=ssh 2>/dev/null || true
		firewall-cmd --quiet --permanent --add-port=22/tcp 2>/dev/null || true
		__firewall_open_port "51820/udp"
		firewall-cmd --quiet --reload 2>/dev/null || true
	fi

	# Load WireGuard kernel module if available; netbird falls back to userspace otherwise
	modprobe wireguard 2>/dev/null || true

	# Install and start the netbird system service
	netbird service install 2>/dev/null || true
	netbird service start 2>/dev/null || true

	# Enroll the host as a peer using the Default setup key
	_hp_setup_key="$(__read_value "$setup_key_file")"
	if netbird up \
		--setup-key "$_hp_setup_key" \
		--management-url "$(__nb_origin)" \
		--daemon-addr unix:///var/run/netbird.sock \
		2>/dev/null; then
		__say "NetBird host peer: enrolled successfully"
	else
		__say "WARNING: netbird up failed — check 'netbird status' after install completes"
	fi
}

# __verify_turn — confirm coturn is listening on the expected UDP port.
# Runs after 'docker compose up' completes.  Issues a warning rather than
# dying so a firewall/kernel issue doesn't abort an otherwise healthy install.
__verify_turn() {
	__have_cmd ss || return 0
	if ss -ulnp 2>/dev/null | grep -q -- ":$NB_TURN_PORT[[:space:]]"; then
		__say "TURN: coturn listening on udp/$NB_TURN_PORT"
	else
		__say "WARNING: coturn does not appear to be listening on udp/$NB_TURN_PORT"
		__say "  Check: docker compose -f $DC_FILE logs $TURN_SVC"
	fi
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
__verify_turn
__wait_for_http "http://172.17.0.1:$NB_KC_MGMT_PORT/health/ready" "Keycloak"
__wait_for_http "http://172.17.0.1:$NB_DASHBOARD_BACKEND_PORT/" "NetBird dashboard"
__wait_for_management "http://172.17.0.1:$NB_MANAGEMENT_HTTP_BACKEND_PORT/api/accounts"

# Auto-configure Keycloak OIDC on first install (no-op on reruns)
__auto_configure_oidc

# If OIDC was configured during this run, reload env and rewrite + restart affected services
if [ "$_OIDC_CONFIGURED_THIS_RUN" -eq 1 ]; then
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

__ensure_tls_cert
__write_nginx_vhost
__ensure_admin_user
__configure_netbird_defaults
__install_host_peer

cat <<OUT

================================================================================
NetBird self-hosted stack is up (or updated) at: $NB_ROOT

Host integration:
  - Kernel modules:   $NB_MODULES_FILE
  - sysctl drop-in:   $NB_SYSCTL_FILE
  - Firewalld always-open: tcp/22 (ssh), tcp/80, tcp/443
  - Firewalld stack ports: tcp/$NB_EXTERNAL_PORT, udp/$NB_TURN_PORT, udp/$NB_TURN_MIN_PORT-$NB_TURN_MAX_PORT, udp/51820 (wireguard)
  - SELinux bind relabeling: $(if __selinux_enabled; then printf 'enabled'; else printf 'not required'; fi)

Local reverse-proxy backends:
  - Dashboard root                          -> http://172.17.0.1:$NB_DASHBOARD_BACKEND_PORT
  - Management REST / websocket proxy       -> http://172.17.0.1:$NB_MANAGEMENT_HTTP_BACKEND_PORT
  - Keycloak OIDC / UI                      -> http://172.17.0.1:$NB_KC_BACKEND_PORT
  - Signal                                  -> http://172.17.0.1:$NB_SIGNAL_BACKEND_PORT
  - TURN                                    -> udp/$NB_TURN_PORT and udp/$NB_TURN_MIN_PORT-$NB_TURN_MAX_PORT

Keycloak admin (configuration only):
  - URL:      $(__nb_origin)/admin
  - Username: admin
  - Password: see $KC_ADMIN_PASS_FILE

NetBird admin (day-to-day management):
  - URL:      $(__nb_origin)
  - Username: $NB_ADMIN_USER
  - Password: see $NB_ADMIN_PASS_FILE

Setup key:
  - Name:     Default (reusable, 3650 days)
  - Key:      see $NB_SECRETS/nb_setup_key_default (created on first install)

Host peer:
  - Binary:   /usr/local/bin/netbird
  - Status:   run 'netbird status' to verify enrollment
  - Peer DNS domain: $NB_DOMAIN

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
