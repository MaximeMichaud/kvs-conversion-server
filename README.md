# KVS Conversion Server

[![CI and CD Validation](https://github.com/MaximeMichaud/kvs-conversion-server/actions/workflows/ci-build-and-push.yml/badge.svg)](https://github.com/MaximeMichaud/kvs-conversion-server/actions/workflows/ci-build-and-push.yml)
[![Made with Bash](https://img.shields.io/badge/Made%20with-Bash-1f425f?logo=gnubash&logoColor=white)](https://www.gnu.org/software/bash/)
[![Docker Image](https://img.shields.io/badge/Docker-image-2496ED?logo=docker&logoColor=white)](https://hub.docker.com/r/maximemichaud/kvs-conversion-server)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

Docker-based remote conversion server for [Kernel Video Sharing (KVS)](https://www.kernel-video-sharing.com). The project installs and runs the software KVS expects for remote video conversion: FTP/FTPS access, per-folder cron jobs, PHP CLI, IonCube, FFmpeg, and ImageMagick.

Tested with KVS **6.1.2** and **6.2.1**.

## Table of Contents

- [What This Provides](#what-this-provides)
- [Quick Start](#quick-start)
- [Installation Options](#installation-options)
- [Management Commands](#management-commands)
- [KVS Configuration Values](#kvs-configuration-values)
- [Requirements](#requirements)
- [Included Software](#included-software)
- [Operational Notes](#operational-notes)
- [Development](#development)
- [Roadmap](#roadmap)
- [Contributing](#contributing)
- [License](#license)

## What This Provides

- Automated Docker-based setup for a KVS remote conversion server.
- FTP, explicit FTPS, and implicit FTPS modes.
- Passive FTP port range configured for Docker publishing.
- Configurable PHP version for KVS compatibility.
- Per-directory cron jobs for KVS `remote_cron.php` execution.
- Persistent data directory mounted from the host.
- Built-in commands to inspect, start, stop, restart, update, and remove the container.

## Quick Start

Run the interactive installer:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/MaximeMichaud/kvs-conversion-server/main/kvs-conversion-server.sh)
```

For unattended deployments:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/MaximeMichaud/kvs-conversion-server/main/kvs-conversion-server.sh) \
  --headless \
  --php-version php8.1 \
  --ftp-mode ftps \
  --ftp-user myuser \
  --num-folders 10 \
  --cpu-limit 4
```

Omit `--ftp-pass` to let headless mode generate a password. Pass it only when your deployment tooling injects a unique secret.

After installation, the script creates:

- `.kvs-server.conf` - local configuration used by management commands.
- `data/` - host directory mounted into the container as `/home/vsftpd`.

Keep `.kvs-server.conf` private. It contains the FTP password and is written with `600` permissions.

## Installation Options

| Option | Description | Default |
| --- | --- | --- |
| `--headless` | Run without interactive prompts. | Disabled |
| `--php-version VERSION` | PHP CLI version: `php7.4` or `php8.1`. | `php8.1` in headless mode |
| `--ftp-mode MODE` | FTP mode: `ftp`, `ftps`, or `ftps_implicit`. | `ftp` |
| `--ftp-user USERNAME` | FTP username created inside the container. | `user` |
| `--ftp-pass PASSWORD` | FTP password. If omitted, a password is generated. | Generated |
| `--ipv4 ADDRESS` | Public IPv4 address used for passive FTP. | Auto-detected |
| `--cpu-limit CORES` | Docker CPU limit. Decimal values are accepted. | All cores |
| `--num-folders NUMBER` | Number of KVS working directories to create. | `5` |
| `--auto-stop-container` | Stop an existing `conversion-server` container during installation. | Disabled |

Environment variables are also supported:

| Variable | Equivalent option |
| --- | --- |
| `KVS_HEADLESS=true` | `--headless` |
| `KVS_PHP_VERSION=php8.1` | `--php-version php8.1` |
| `KVS_FTP_MODE=ftps` | `--ftp-mode ftps` |
| `KVS_IPV4_ADDRESS=203.0.113.10` | `--ipv4 203.0.113.10` |
| `KVS_CPU_LIMIT=4` | `--cpu-limit 4` |
| `KVS_FTP_USER=myuser` | `--ftp-user myuser` |
| `KVS_FTP_PASS=unique-secret` | `--ftp-pass unique-secret` |
| `KVS_NUM_FOLDERS=10` | `--num-folders 10` |
| `KVS_AUTO_STOP_CONTAINER=true` | `--auto-stop-container` |

CLI options take precedence over environment variables.

Omit `KVS_FTP_PASS` in headless mode to generate a password automatically.

## Management Commands

Run these commands from the installation directory or one of its subdirectories. The script searches parent directories for `.kvs-server.conf`.

Set `KVS_CONFIG=/path/to/.kvs-server.conf` when managing an installation from another working directory.

| Command | Description |
| --- | --- |
| `./kvs-conversion-server.sh status` | Show container status, health, ports, and resource usage. |
| `./kvs-conversion-server.sh logs` | Show container logs. |
| `./kvs-conversion-server.sh logs -f` | Follow container logs. |
| `./kvs-conversion-server.sh start` | Start the existing container, or recreate it from `.kvs-server.conf` if needed. |
| `./kvs-conversion-server.sh stop` | Stop the container. |
| `./kvs-conversion-server.sh restart` | Restart the container. |
| `./kvs-conversion-server.sh info` | Show saved configuration and live container details. |
| `./kvs-conversion-server.sh update` | Pull the latest Docker image. |
| `./kvs-conversion-server.sh remove` | Remove the container and optionally remove local data/config files. |

Aliases:

- `status` / `ps`
- `start` / `up`
- `stop` / `down`
- `remove` / `rm`

## KVS Configuration Values

The installer prints the values to enter in the KVS admin panel after the container starts.

| KVS field | Value |
| --- | --- |
| Connection type | FTP |
| Force SSL connection | `true` for `ftps` and `ftps_implicit`, otherwise `false` |
| FTP host | Public IPv4 address detected or passed with `--ipv4` |
| FTP port | `21` for `ftp` and `ftps`, `990` for `ftps_implicit` |
| FTP user | Value passed with `--ftp-user` |
| FTP password | Value passed with `--ftp-pass` or generated by the installer |
| FTP directory | One folder per KVS server slot, for example `01`, `02`, `03` |

Each directory is intended for one KVS use case. If you need isolated workloads, create enough folders during installation and assign them separately in KVS.

## Requirements

### Host

- Linux host with Docker support.
- amd64 architecture.
- Public network path to the FTP/FTPS control port and passive ports.
- Enough storage for uploaded source files and converted outputs.

If Docker is not installed, the installer attempts to install it with the official Docker installation script from `get.docker.com`. Review this behavior before running the installer on production systems.

### Ports

| Mode | Control port | Passive ports |
| --- | --- | --- |
| `ftp` | `21` | `21100-21110` |
| `ftps` | `21` | `21100-21110` |
| `ftps_implicit` | `990` | `21100-21110` |

The local port check only confirms that Docker is listening on the host. You still need to verify firewall, NAT, and provider-level rules from an external network.

### Hardware

- **RAM**: 1 GB minimum is usually enough for the container overhead.
- **CPU**: Video conversion is CPU-bound. More cores and higher clock speed reduce processing time.
- **Storage**: Size depends on raw upload volume, conversion outputs, and retention policy.

GPU acceleration is not currently tested.

## Included Software

The image is based on Debian 13 slim and includes:

- VsFTPd 3.0.5
- PHP 7.4 CLI for KVS versions below 6.2
- PHP 8.1 CLI for KVS 6.2 and newer
- IonCube Loader for PHP 7.4 and 8.1
- FFmpeg 7.1 LTS from Debian packages
- ImageMagick 7.x from Debian packages

PHP packages are installed from [packages.sury.org](https://sury.org), which provides maintained builds for multiple PHP versions on Debian.

## Operational Notes

### Data Layout

The installer mounts local `data/` into the container at `/home/vsftpd`.

Example container paths:

```text
/home/vsftpd/myuser/01
/home/vsftpd/myuser/02
/home/vsftpd/myuser/03
```

Each folder gets a cron entry that runs `remote_cron.php` when KVS uploads it.

### Single Instance Model

Use one installation directory per deployment. The script manages a fixed container name, `conversion-server`, and fixed host ports, so it is intended for one active managed instance per host.

For separate projects, keep separate directories and stop one instance before switching to another.

### Networked Environments

The image is designed for straightforward public FTP/FTPS connectivity. If your server is behind restrictive firewalls, NAT, private routing, or provider filtering, validate both the control port and the passive port range before configuring KVS.

Private network overlays such as WireGuard or Tailscale can work, but they need matching KVS-side connectivity.

## Development

Useful local checks:

```bash
bash -n kvs-conversion-server.sh scripts/*.sh
shellcheck --severity=warning kvs-conversion-server.sh scripts/create_folders.sh scripts/run-vsftpd.sh scripts/entrypoint.sh
hadolint Dockerfile
yamllint .github .pre-commit-config.yaml .yamllint .hadolint.yaml
docker build -t kvs-conversion-server:test .
```

Run the container manually for local testing:

```bash
docker run --rm -d \
  --name kvs-test \
  -e FTP_USER=testuser \
  -e FTP_PASS=change-me-securely \
  -e PASV_ADDRESS=127.0.0.1 \
  -e NUM_FOLDERS=3 \
  -e PHP_VERSION=php8.1 \
  -e FTP_MODE=ftp \
  -p 2121:21 \
  -p 21100-21110:21100-21110 \
  kvs-conversion-server:test
```

## Roadmap

- Optional IonCube installation for KVS setups that do not need encoded PHP files.
- FFmpeg version selection for deployments that require a specific codec or compatibility target.

Project planning is tracked in the [KVS Conversion Server project board](https://github.com/users/MaximeMichaud/projects/3).

## Contributing

Issues and pull requests are welcome. For changes that affect runtime behavior, include:

- The problem being fixed.
- The expected behavior after the change.
- The commands used to validate the change.

## License

This project is licensed under the [MIT License](LICENSE).
