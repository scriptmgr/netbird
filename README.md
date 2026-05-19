# NetBird Self-Hosted Installer

A single self-contained `install.sh` that bootstraps and updates a production-ready self-hosted NetBird stack.

Components managed:

- **Keycloak 26.x** — OIDC identity provider, user management, admin UI
- **NetBird management** — control plane, peer management, access policies
- **NetBird dashboard** — web UI
- **NetBird signal** — WebRTC signaling relay
- **Coturn** — TURN relay for peers behind NAT

All templates and logic are baked into `install.sh`. At install time the script writes runtime-owned files under `/opt/netbird` and preserves generated secrets across reruns.

---

## Requirements

- Linux host (Debian/Ubuntu, AlmaLinux/RHEL 9+, Fedora, openSUSE, Arch)
- Root access
- Internet access (Docker Hub, Quay.io)
- A valid FQDN pointing to the host (e.g. `vpn.example.com`)
- An external reverse proxy you manage separately (nginx, Caddy, HAProxy …)

---

## Quick start

```sh
git clone https://github.com/scriptmgr/netbird
cd netbird

# Required: tell the installer your domain
export NB_DOMAIN=vpn.example.com

sudo sh ./install.sh
```

Or use a `.env` file (preferred — see [Configuration](#configuration)):

```sh
cp /dev/null .env
echo "NB_DOMAIN=vpn.example.com" >> .env
sudo sh ./install.sh
```

---

## Configuration

All settings are controlled by environment variables. The script sources a `.env` file from its own directory before applying defaults, so you can set persistent site values without modifying the script.

### `.env` — site-specific overrides

Create a `.env` file next to `install.sh` (it is `.gitignore`-d):

```sh
# .env — site-specific installer overrides
NB_DOMAIN=vpn.example.com          # REQUIRED — must be a valid FQDN
NB_ORG=netbird                     # Keycloak realm name (default: netbird)
NB_EXTERNAL_PORT=443               # Port your reverse proxy listens on (default: 443)
NB_EMAIL_FROM_NAME=NetBird         # Display name for outbound email (default: NetBird)
NB_TIMEZONE=America/New_York       # TZ for containers (default: America/New_York)
NB_EMAIL_SMTP_HOST=127.0.0.1       # SMTP relay host
NB_EMAIL_SMTP_PORT=25              # SMTP relay port
```

### All configuration variables

| Variable | Default | Description |
|---|---|---|
| `NB_DOMAIN` | auto-detected from hostname | **Required.** Public FQDN for the deployment. The script dies if this is not a valid FQDN. |
| `NB_ORG` | `netbird` | Keycloak realm name. Also sets the OIDC issuer path. |
| `NB_ROOT` | `/opt/netbird` | Runtime directory for all generated files. |
| `NB_EXTERNAL_PORT` | `443` | External TCP port on the reverse proxy. |
| `NB_TIMEZONE` | `America/New_York` | Container timezone. |
| `NB_EMAIL_FROM_NAME` | `NetBird` | Sender display name for outbound email. |
| `NB_EMAIL_FROM_USER` | `no-reply@$NB_DOMAIN` | Sender address. |
| `NB_EMAIL_SMTP_HOST` | `127.0.0.1` | SMTP relay host. |
| `NB_EMAIL_SMTP_PORT` | `25` | SMTP relay port. |
| `NB_DOCKER_NETWORK` | `netbird` | Docker bridge network name. |
| `NB_TURN_PORT` | `3478` | TURN/STUN UDP port. |
| `NB_TURN_MIN_PORT` | `49152` | TURN relay port range start. |
| `NB_TURN_MAX_PORT` | `49252` | TURN relay port range end. |

---

## What the script does

1. **Detects and validates `NB_DOMAIN`** — dies immediately with a clear message if the domain is not a valid FQDN.
2. **Configures kernel modules** — persists `overlay` and `br_netfilter` in `/etc/modules-load.d/netbird.conf` and loads them; idempotent on reruns.
3. **Configures sysctl** — writes `/etc/sysctl.d/99-netbird.conf` with ip_forward, bridge-nf-call, src_valid_mark, and rp_filter settings; also patches `/etc/sysctl.conf` in-place if a key exists there with the wrong value.
4. **Installs Docker Engine** — from the official Docker repository for the detected distro. On RHEL/AlmaLinux/Fedora, removes the conflicting distro `containerd` package first. On openSUSE/Arch, creates the Docker CLI plugin symlink for `docker-compose`.
5. **Opens firewall ports** — on RHEL-family hosts: installs `firewalld` + `container-selinux`, enables firewalld, opens `$NB_EXTERNAL_PORT/tcp`, `3478/udp`, and `49152-49252/udp`.
6. **Generates and preserves secrets** — Keycloak admin password, Keycloak database password, TURN credential, and the NetBird datastore encryption key. Existing secrets are never rotated.
7. **Writes all config files** — `docker-compose.yml`, `keycloak.env`, `netbird.env`, `dashboard.env`, `management.json`, `turnserver.conf` — all under `/opt/netbird`.
8. **Starts the stack** — `docker compose up -d` with image pulls.
9. **Auto-configures Keycloak** — creates the realm (`$NB_ORG`), PKCE public client, service account client, audience mapper, and realm-admin role assignment via the Keycloak admin REST API. No manual Keycloak setup required. This step is a no-op on reruns once credentials are written.
10. **Restarts affected services** — management and dashboard are restarted with the real OIDC credentials after the auto-configuration step.

---

## Runtime layout

```
/opt/netbird/
  compose/
    docker-compose.yml        # generated by install.sh
  etc/
    keycloak.env              # Keycloak + Postgres env vars
    netbird.env               # NetBird OIDC config
    dashboard.env             # Dashboard env vars
    management.json           # Management server config
    turnserver.conf           # Coturn config
  secrets/
    kc_admin_password         # Keycloak admin password (mode 600)
    kc_db_password            # Postgres password (mode 600)
    turn_password             # TURN credential (mode 600)
    turn_user                 # TURN username (mode 600)
    netbird_datastore_key     # AES-256 datastore key (mode 600)
  data/
    keycloak/                 # Keycloak runtime data
    keycloak-db/              # Postgres data
    management/               # Management server data
    signal/                   # Signal server data
    turn/                     # Coturn data
  log/                        # Reserved for future use
  state/                      # Reserved for future use
```

---

## Local backends for your reverse proxy

The stack binds all backends to `127.0.0.1` only. Your reverse proxy publishes them on `NB_DOMAIN:NB_EXTERNAL_PORT`.

| Purpose | Default local backend |
|---|---|
| Dashboard | `http://127.0.0.1:18080` |
| Management REST / WebSocket | `http://127.0.0.1:18081` |
| Keycloak UI / OIDC | `http://127.0.0.1:18082` |
| Keycloak management (health) | `http://127.0.0.1:18083` |
| Signal | `http://127.0.0.1:10000` |
| TURN | `udp/3478`, `udp/49152–49252` |

### Typical reverse-proxy path routing

| Path prefix | Route to |
|---|---|
| `/realms/*`, `/resources/*`, `/admin/*` | Keycloak backend |
| `/api/*`, `/management.ManagementService/*` | Management backend |
| `/ws-proxy/management*` | Management backend (WebSocket) |
| `/signalexchange.SignalExchange/*`, `/ws-proxy/signal*` | Signal backend |
| `/*` (catch-all) | Dashboard backend |

TURN runs with `network_mode: host` so peers reach relay ports directly without proxy involvement.

---

## Keycloak admin UI

After install the admin console is reachable at:

```
https://<NB_DOMAIN>:<NB_EXTERNAL_PORT>
```

- **Username:** `admin`
- **Password:** contents of `/opt/netbird/secrets/kc_admin_password`

The NetBird realm (name = `$NB_ORG`), PKCE client (`netbird-client`), and management service account (`netbird-management`) are created automatically on first run.

---

## Upgrading

The script is fully idempotent. To upgrade:

```sh
cd netbird
git pull
sudo sh ./install.sh
```

The script:

- preserves all generated secrets and credentials
- rewrites config files from the preserved secret set
- pulls the latest images (`docker compose pull`)
- restarts the stack

To pin a specific Keycloak version, edit the `image:` line for the `keycloak` service in `docker-compose.yml` after first install and do not re-run install.sh (which would overwrite it). Or set the version in a fork of the script.

### Rotating credentials

To rotate a specific credential, delete the file under `/opt/netbird/secrets/` and rerun the installer:

```sh
rm /opt/netbird/secrets/turn_password
sudo sh ./install.sh
```

To rotate the Keycloak admin password, delete `kc_admin_password` and rerun. Keycloak will be updated on next startup because the password is injected via the `KEYCLOAK_ADMIN_PASSWORD` env var.

**Do not rotate `netbird_datastore_key`** unless you are intentionally wiping all management server state — the key is used to decrypt the stored database.

---

## Log rotation

All containers use the Docker `json-file` log driver with:

- `max-size: 10m` — rotate each log file at 10 MiB
- `max-file: 3` — keep 3 rotated files per container

This keeps total log usage bounded at ~30 MiB per container. To change the limits, edit `docker-compose.yml` under `/opt/netbird/compose/` and restart the stack.

---

## Distro-specific notes

### AlmaLinux 9 / RHEL 9+ / Rocky Linux

- Removes the distro `containerd` package before installing Docker's `containerd.io`
- Installs `firewalld`, `policycoreutils-python-utils`, and `container-selinux`
- SELinux bind mounts use the `,Z` relabeling option automatically

### Fedora

- Same `containerd` removal as RHEL family (distro package conflicts with Docker's)

### openSUSE / Arch Linux / Manjaro

- Installs distro `docker-compose` package
- Creates `/usr/lib/docker/cli-plugins/docker-compose` symlink so the `docker compose` CLI plugin path works

---

## License

MIT
