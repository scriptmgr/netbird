# NetBird Self-Hosted Installer

This project provides a **POSIX-compliant** installation script (`install.sh`) to set up and update a full [NetBird](https://github.com/netbirdio/netbird) server stack, including:

- **ZITADEL** (OpenID Connect identity provider)
- **NetBird Management** service
- **NetBird Dashboard**
- **NetBird Signal** server
- **Coturn** (TURN server for peer connectivity)

The script is idempotent — you can safely re-run it to update images, refresh configs, or reset the admin account without breaking existing data.


## Features

- 🚀 **Automated install/upgrade**: pulls Docker Engine + Compose from official Docker repos (no `docker.io` package).
- 🔑 **Secure admin bootstrap**:
  - Default admin username: `administrator`
  - Password: **randomly generated** and stored at `/opt/netbird/secrets/admin_password`
  - Re-runs will reset the admin password safely.
- 📧 **Email support**: Uses the host’s local MTA (`127.0.0.1:25`) for notifications.
- 🔒 **Reverse proxy ready**: Services run on internal ports; you expose them via your proxy on **port 64453**.
- ♻️ **Safe updates**: Existing volumes and data are preserved; re-runs only update configs/images.


## Requirements

- Linux host (tested on Debian/Ubuntu, Fedora, CentOS, RHEL, Arch, openSUSE)
- Root privileges (`sudo sh install.sh`)
- Internet access to pull images from:
  - [Docker Hub](https://hub.docker.com)
  - [GHCR](https://github.com/netbirdio/netbird/pkgs/container)


## Installation

1. Clone or download this repo:

```sh
git clone https://github.com/scriptmgr/netbird
cd netbird
````

2. Run the installer:

```sh
sudo sh ./install.sh
```

   > The script will install Docker (if missing), configure NetBird services, and bring them up with `docker compose`.



## Service Layout

The installer creates a `docker-compose.yml` under `/opt/netbird/compose` with the following services:

- `zitadel` + `zitadel-db` – Identity provider & database
- `management` – NetBird management API
- `dashboard` – Web UI
- `signal` – Peer signal server
- `coturn` – TURN/STUN relay

All services share a dedicated Docker network `nb_net`.


## Reverse Proxy

All services are **internal**. You must publish them via a reverse proxy (Nginx, Traefik, Caddy, etc.). Example mapping:

- External `https://your-domain:64453` → NetBird Dashboard (`dashboard`)
- External `https://your-domain:64453` → NetBird Management API (`management`)
- External `https://your-domain:64453` → ZITADEL (`zitadel`)

TURN ports (`udp/3478`, `udp/49152-49252`) must be open between peers and the server.


## Admin Account

- Username: `administrator@<ORG>.<DOMAIN>`
- Password: stored in `/opt/netbird/secrets/admin_password`

On first run, the user is created in ZITADEL. On subsequent runs, the password is reset to match the file.


## Configuration

Key config files live under `/opt/netbird/etc`:

- `zitadel.env` – bootstrap env for IdP
- `netbird.env` – NetBird environment config
- `management.json` – Management OIDC settings
- `zitadel-secrets.yaml` – IdP setup secrets


## Updating

Simply re-run:

```sh
sudo sh ./install.sh
```

The script will:

- Pull latest container images
- Preserve volumes and secrets
- Restart services with updated configs


## Logs & Data

- Logs: `/opt/netbird/log`
- Secrets: `/opt/netbird/secrets`
- Data volumes: `/opt/netbird/data`


## Next Steps

1. Configure your reverse proxy to forward `:64453` to the internal services.

2. Log into ZITADEL as `administrator@<ORG>.<DOMAIN>` with the password from `/opt/netbird/secrets/admin_password`.

3. In ZITADEL, create a confidential OIDC app for NetBird and add its `ClientID`/`ClientSecret` to `/opt/netbird/etc/management.json`.

4. Restart the stack:

   ```sh
   cd /opt/netbird/compose
   docker compose up -d
   ```

5. Use the dashboard to invite/join clients.


## Notes

- The installer does **not** expose services directly on the host. Always use a reverse proxy with TLS.
- If ZITADEL CLI syntax changes, you may need to adjust admin password reset commands manually inside the container.


## License

MIT
