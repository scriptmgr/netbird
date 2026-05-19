# NetBird Self-Hosted Installer

POSIX sh installer and updater for a fully self-hosted [NetBird](https://netbird.io) VPN stack.

## What it does

- Installs Docker + Docker Compose on the target host (detects distro automatically)
- Writes a `docker-compose.yml` with all six NetBird services: Keycloak, management, dashboard, signal, coturn, relay
- Configures Keycloak via its admin REST API: realm, PKCE client, service-account client, audience mapper
- Generates a `.env` file for NetBird management and Keycloak with all derived secrets
- Supports upgrade: re-running the script pulls new images and restarts services

## Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `NB_DOMAIN` | auto-detected FQDN | Public hostname for the NetBird stack |
| `NB_ORG` | `netbird` | Keycloak realm name |
| `NB_EXTERNAL_PORT` | `443` | External HTTPS port |
| `NB_EMAIL` | — | Admin e-mail for Keycloak |
| `NB_EMAIL_FROM` | `no-reply@{NB_DOMAIN}` | From address for Keycloak e-mails |
| `NB_EMAIL_FROM_NAME` | `NetBird` | Display name for outbound e-mails |
| `NB_TIMEZONE` | `UTC` | Container timezone |
| `NB_ROOT` | `/opt/netbird` | Installation root on host |
| `NB_KC_VERSION` | `26.2` | Keycloak image tag |
| `NB_MGMT_VERSION` | `latest` | NetBird management image tag |

Variables are read from `{script_dir}/.env` if present (never committed), then from the environment, then from the defaults above.

## Runtime layout

```
/opt/netbird/
├── docker-compose.yml
├── management.json        # NetBird management config
├── .env                   # Generated secrets — never commit
└── data/
    ├── keycloak/          # Keycloak DB
    ├── management/        # Peer store
    └── coturn/            # TURN credentials
```

## Distro support

Tested: Ubuntu 22.04+, Debian 12+, AlmaLinux/RHEL 9+, Fedora 39+, openSUSE Leap/Tumbleweed, Arch Linux.

## Site-specific overrides

Copy `.env.example` to `.env` in the same directory as `install.sh` before running:

```sh
NB_DOMAIN=vpn.example.com
NB_EXTERNAL_PORT=443
NB_EMAIL=admin@example.com
NB_TIMEZONE=America/New_York
```
