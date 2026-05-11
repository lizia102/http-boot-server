# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

A one-click PXE/UEFI HTTP Boot server for Linux network installations. Supports RHEL, CentOS, Ubuntu, Debian, and SLES across x86_64, x86, and ARM64 architectures. All user-facing text (UI, comments, docs) is in Chinese.

## Deployment

```bash
chmod +x setup.sh
sudo ./setup.sh
```

`setup.sh` must run as root on a RHEL 7+ or Ubuntu/Debian host. It auto-detects the server IP and network interface, then installs and configures all four services in one pass. There is no build step or test suite — this is a deployment tool, not a library.

To customize network settings (DHCP range, ports), edit the variables at the top of `setup.sh` before running it.

## Architecture

Four cooperating services, all deployed to `/var/lib/http-boot-server/`:

| Service | Port | Role |
| --- | --- | --- |
| DHCP | UDP 67/68 | Assigns IPs, routes clients to architecture-specific boot files |
| TFTP | UDP 69 | Serves boot binaries (pxelinux.0, shimx64.efi, grub.cfg) |
| Nginx | 80→443 | HTTPS reverse proxy for Flask; static file server for `/boot/` |
| Flask | 8443 | Web UI + REST API for image management |

Nginx proxies `/upload/` and `/api/` to Flask. Boot files are served directly by Nginx from the `boot/` directory.

## Key Files

- **`setup.sh`** — Orchestrator. Detects OS (RHEL vs Debian), installs packages, renders config templates, copies binaries, configures firewall, starts services.
- **`upload_server.py`** — Flask app. Handles file upload/download/delete, manages `metadata.json` for default kernel/initrd, auto-generates GRUB menu entries on ISO upload, extracts SLES ISOs to `repos/` in background threads.
- **`templates/index.html`** — Jinja2 template for the drag-and-drop web management UI (Bootstrap 5).
- **`config/dhcpd.conf.template`** — DHCP config with shell variable placeholders (`${SERVER_IP}`, `${DHCP_SUBNET}`, etc.). Uses `option arch code 93` for architecture-based boot file selection.
- **`config/nginx.conf`** — Nginx config using `envsubst` placeholders (`${INSTALL_DIR}`, `${NGINX_USER}`).
- **`config/grub.cfg.template`** — GRUB config using GRUB's own `${next_server}` variable (resolved at boot time from DHCP), not shell variables.

## Template Variable System

Config templates use two different substitution mechanisms:

- **Shell variables** (`${VAR}`) in `dhcpd.conf.template` and `setup.sh` inline heredocs — rendered by `render_template()` using `sed`.
- **`envsubst`** for `nginx.conf` — only replaces `${INSTALL_DIR}` and `${NGINX_USER}` (other `$` variables are preserved for nginx).
- **GRUB variables** (`${next_server}`) in `grub.cfg.template` — NOT substituted at deploy time; resolved by GRUB at boot time from DHCP option 66.

## Dynamic GRUB Entries

When an ISO is uploaded via the web UI, `upload_server.py` appends a GRUB `menuentry` block to `boot/grub/grub.cfg` tagged with `# <dynamic iso="filename">` markers. Deleting an ISO removes its tagged entry. The `grub-custom.cfg` file is sourced if present, allowing manual extensions.

## Service Management

```bash
systemctl status dhcpd xinetd nginx http-boot-upload
systemctl restart <service-name>
journalctl -u <service-name>
```

On Debian/Ubuntu, replace `dhcpd` with `isc-dhcp-server` and `xinetd` with `tftpd-hpa`.

## Git 工作流规范

- **自动提交**: 在完成每个逻辑任务、功能点或 Bug 修复后，必须自动执行 Git commit。
- **提交信息**: Commit message 需严格遵循 Conventional Commits 规范（例如 `feat:`, `fix:`, `docs:`, `refactor:`）。
- **同步远端**:
  1. 在提交前，先执行 `git pull --rebase` 以确保本地代码是最新的。
  2. Commit 完成后，立即执行 `git push` 将改动同步到 GitHub。

## Project Conventions

- The project uses `render_template()` in `setup.sh` for config generation — a simple `sed`-based variable replacer, not a real template engine.
- `metadata.json` (created at runtime) stores default kernel/initrd selections. It is not checked into the repo.
- The `boot/grub/grub.cfg` in the repo root is a deployed artifact (runtime config), not a source template. The source template is `config/grub.cfg.template`.
