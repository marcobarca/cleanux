# cleanux

![ShellCheck](https://github.com/marcobarca/cleanux/actions/workflows/shellcheck.yml/badge.svg)
![Version](https://img.shields.io/badge/version-2.0.0-blue)
![License](https://img.shields.io/badge/license-MIT-green)

Periodic server cleanup tool for Linux. One command to free gigabytes: Docker build cache, dev caches, journal logs, snap revisions, core dumps, and more.

> On active dev/homelab servers, Docker build cache alone can eat **50+ GB per week**.

<!-- demo GIF here -->

## Install

```bash
curl -fsSL https://raw.githubusercontent.com/marcobarca/cleanux/main/install.sh | sudo bash
```

Or clone:

```bash
git clone https://github.com/marcobarca/cleanux
cd cleanux && sudo bash install.sh
```

## Quick start

```bash
# Preview what would be freed — no changes made
cleanux --dry-run

# Clean everything (safe defaults)
sudo cleanux

# Enable all opt-in modules
sudo cleanux --all

# Pick modules interactively
sudo cleanux --interactive

# Silent mode for cron
sudo cleanux -q
```

## What it cleans

| Module | Default | Notes |
|---|---|---|
| Docker build cache | ✅ | Largest win, fully safe |
| Docker stopped containers | ✅ | Safe |
| Docker dangling images | ✅ | Untagged layers only |
| Docker unused volumes | ❌ opt-in | `--enable-volumes` |
| Journal logs | ✅ | Keeps last 14 days |
| APT / dnf / pacman / brew | ✅ | Package manager cache |
| APT autoremove | ❌ opt-in | `--enable-autoremove` |
| npm / yarn / pnpm cache | ✅ | |
| pip cache | ✅ | |
| Cargo registry cache | ❌ opt-in | `--enable-cargo` |
| Go build cache | ❌ opt-in | `--enable-go` |
| Snap old revisions | ✅ | Disabled revisions only |
| Core dumps | ✅ | `/var/crash`, `core.*` |
| /tmp old files | ✅ | Older than 7 days |
| Thumbnail cache | ❌ opt-in | `--enable-thumbnails` |
| Brew bundle cleanup | ✅ | macOS only, if Brewfile exists |

## All options

```
Commands:
  --schedule [CRON]    Install cron job (default: "0 3 * * 0")
  --systemd            Install systemd timer (Sun 03:00)

Options:
  -n, --dry-run            Preview what would be cleaned, without changes
  -i, --interactive        Choose modules interactively before running
  -q, --quiet              Suppress output (log file still written)
  -c, --config FILE        Config file (default: /etc/cleanux.conf)
      --all                Enable all opt-in modules
      --all-users          Clean dev caches for all users in /home
      --since DAYS         Only clean items older than N days
      --enable-volumes     Docker unused volumes
      --enable-autoremove  apt autoremove
      --enable-cargo       Cargo registry cache
      --enable-go          Go build cache
      --enable-thumbnails  Thumbnail cache
      --html-report        Generate HTML report after run
```

## Scheduling

**cron:**
```bash
sudo cleanux --schedule              # every Sunday at 03:00 (default)
sudo cleanux --schedule "0 2 * * *"  # every day at 02:00
```

**systemd timer:**
```bash
sudo cleanux --systemd
systemctl status cleanux.timer
```

## Configuration

Edit `/etc/cleanux.conf`:

```bash
# Docker
DOCKER_VOLUMES=false

# Logs
JOURNAL_KEEP_DAYS=14

# Dev caches
CARGO_CACHE=false
GO_CACHE=false

# Notifications
WEBHOOK_URL="https://hooks.slack.com/..."   # Slack / Discord
NOTIFY_EMAIL="you@example.com"

# HTML report
HTML_REPORT=true
HTML_REPORT_PATH="/var/log/cleanux-report.html"

# Only run if disk >= N% full
DISK_THRESHOLD=80

# Log rotation
LOG_MAX_MB=10
```

## Notifications

cleanux can notify after each run via **Slack**, **Discord**, or **email**:

```bash
# Slack / Discord (webhook)
WEBHOOK_URL="https://hooks.slack.com/services/..."

# Email (requires mail command)
NOTIFY_EMAIL="you@example.com"
```

## Plugins

Drop any `.sh` file into `/etc/cleanux.d/` to extend cleanux with custom cleanup modules. Each plugin is sourced before the run.

```bash
# /etc/cleanux.d/myapp.sh
clean_myapp() {
  echo -e "\nMyApp cache"
  rm -rf /var/myapp/cache/*
}
```

## Supported systems

- Ubuntu / Debian (apt)
- Fedora / RHEL / CentOS (dnf / yum)
- Arch Linux (pacman)
- macOS (brew)

## Log

Each run appended to `/var/log/cleanux.log`. Auto-rotated at 10 MB.

## License

MIT
