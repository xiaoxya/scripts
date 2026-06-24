# Linux Init Scripts

This repository contains a cross-distro Linux development machine initializer.

## Usage

```bash
chmod +x linux-init.sh
./linux-init.sh
```

Audit planned actions without changing the system:

```bash
./linux-init.sh --dry-run
```

Skip confirmation prompts:

```bash
./linux-init.sh --yes
```

## Supported distributions

- Ubuntu / Debian
- Fedora
- CentOS / RHEL / Rocky Linux / AlmaLinux
- Arch Linux / Manjaro

## What it does

- Detects the Linux distribution and package manager.
- Updates package metadata.
- Installs common backend development tools.
- Installs Docker, preferring Docker official repositories when available.
- Installs Node.js LTS through `nvm`.
- Installs Python and Go toolchains.
- Adds conservative shell aliases and Git defaults without overwriting existing settings.
- Performs low-risk security checks without automatically changing SSH or firewall settings.

The script is intentionally interactive. Potentially disruptive actions, such as changing the default shell or adding a user to the Docker group, require confirmation unless `--yes` is used.
