# cleanux

[![ShellCheck](https://github.com/marcobarca/cleanux/actions/workflows/shellcheck.yml/badge.svg)](https://github.com/marcobarca/cleanux/actions/workflows/shellcheck.yml)
![Version](https://img.shields.io/badge/version-2.0.0-blue)
![License](https://img.shields.io/badge/license-MIT-green)
![Platform](https://img.shields.io/badge/platform-Linux%20%7C%20macOS-lightgrey)

cleanux is a bash script that removes temporary files, caches, and other junk that accumulates on Linux servers and development machines over time.

It runs either manually or on a schedule, and has a `--dry-run` mode that shows exactly what would be deleted before doing anything.

---

## Install and run

**1. Install**

```bash
curl -fsSL https://raw.githubusercontent.com/marcobarca/cleanux/main/install.sh | sudo bash
```

This copies `cleanux` to `/usr/local/bin` and creates a default config at `/etc/cleanux.conf`.

**2. Launch**

```bash
cleanux
```

That's it. An interactive menu opens where you can configure modules, set a schedule, and run the cleanup — no need to remember any flags.

**3. Done**

From that point on, if you set up a schedule from the menu, cleanux runs automatically in the background. You don't need to do anything else.

---

> If you want to skip the menu and run directly: `sudo cleanux --dry-run` to preview, `sudo cleanux -q` for a silent run.

---

## What it deletes

**Docker**
- Build cache — layers left over from `docker build` that are no longer referenced
- Stopped containers — containers that exited and were never removed
- Dangling images — untagged image layers with no associated container
- Unused volumes *(opt-in)* — volumes not mounted by any container

**System logs**
- Journal entries older than 14 days (configurable) via `journalctl --vacuum-time`

**Package manager cache**
- APT: files in `/var/cache/apt/archives` — downloaded `.deb` packages no longer needed
- dnf / yum / pacman / brew: equivalent cache directories per package manager
- Unused dependency packages *(opt-in)* via `apt autoremove`

**Dev tool caches**
- npm / yarn / pnpm: downloaded package tarballs in the local cache directory
- pip: downloaded wheel files in `~/.cache/pip`
- Cargo *(opt-in)*: source and compiled artifacts in `~/.cargo/registry/cache`
- Go *(opt-in)*: build cache in the directory returned by `go env GOCACHE`

**System**
- Snap: old disabled revisions left behind after snap updates
- Core dumps: `.crash` files in `/var/crash` and `core.*` files in `/tmp` and `/var`
- `/tmp`: files and directories not accessed in the last 7 days (configurable)

**Desktop *(opt-in)***
- Thumbnail cache: `~/.cache/thumbnails/normal` and `~/.cache/thumbnails/large`

**macOS only**
- Homebrew: runs `brew bundle cleanup` to remove formulae not listed in `Brewfile`

---

## Install

```bash
curl -fsSL https://raw.githubusercontent.com/marcobarca/cleanux/main/install.sh | sudo bash
```

Or manually:

```bash
git clone https://github.com/marcobarca/cleanux
cd cleanux && sudo bash install.sh
```

The installer copies `cleanux` to `/usr/local/bin`, writes a default config to `/etc/cleanux.conf`, and optionally sets up a weekly cron job.

---

## Usage

```bash
# Show what would be deleted — no changes made
sudo cleanux --dry-run

# Run with defaults
sudo cleanux

# Enable all opt-in modules
sudo cleanux --all

# Choose which modules to run interactively
sudo cleanux --interactive

# Only target files older than 30 days
sudo cleanux --since 30

# Silent — no output, for use in cron
sudo cleanux -q
```

---

## Scheduling

```bash
# Set up a weekly cron job (Sunday at 03:00)
sudo cleanux --schedule

# Custom schedule (any valid cron expression)
sudo cleanux --schedule "0 2 * * *"

# Use a systemd timer instead of cron
sudo cleanux --systemd
```

---

## Configuration

All defaults can be overridden in `/etc/cleanux.conf`:

```bash
# How many days of journal logs to keep
JOURNAL_KEEP_DAYS=14

# Opt-in modules (false by default)
DOCKER_VOLUMES=false
APT_AUTOREMOVE=false
CARGO_CACHE=false
GO_CACHE=false
THUMBNAIL_CACHE=false

# Skip the run entirely if disk usage is below this percentage
# 0 means always run
DISK_THRESHOLD=0

# Clean dev caches for every user in /home, not just the current one
ALL_USERS=false

# Log file path and max size before rotation
LOG_FILE="/var/log/cleanux.log"
LOG_MAX_MB=10

# Send a summary after each run
WEBHOOK_URL=""        # Slack or Discord webhook URL
NOTIFY_EMAIL=""       # requires the mail command to be configured

# Write an HTML report after each run
HTML_REPORT=false
HTML_REPORT_PATH="/var/log/cleanux-report.html"
```

---

## Notifications

After a run cleanux can send a short summary (hostname, space freed, disk usage) to a Slack or Discord channel, or via email.

```bash
# In /etc/cleanux.conf

# Slack / Discord
WEBHOOK_URL="https://hooks.slack.com/services/..."

# Email (requires mail to be installed and configured)
NOTIFY_EMAIL="you@example.com"
```

---

## Plugins

Place any `.sh` file in `/etc/cleanux.d/` to add custom cleanup steps. Files are sourced automatically at startup.

```bash
# /etc/cleanux.d/myapp.sh

clean_myapp() {
  echo -e "\nMyApp"
  info "Clearing render cache..."
  rm -rf /var/myapp/cache/renders/*
  ok "Done"
}
```

---

## All options

```
Commands:
  --schedule [CRON]        Install cron job  (default: "0 3 * * 0")
  --systemd                Install and enable systemd timer

Options:
  -n, --dry-run            Show what would be deleted, without doing anything
  -i, --interactive        Select modules interactively before running
  -q, --quiet              No output (log is still written)
  -c, --config FILE        Use a custom config file
      --all                Enable all opt-in modules
      --all-users          Clean dev caches for every user in /home
      --since DAYS         Only target files older than N days
      --enable-volumes     Docker unused volumes
      --enable-autoremove  apt autoremove
      --enable-cargo       Cargo registry cache
      --enable-go          Go build cache
      --enable-thumbnails  Thumbnail cache
      --html-report        Write an HTML report after the run
  -v, --version            Print version
  -h, --help               Show this help
```

---

## Supported systems

| System | Package manager |
|---|---|
| Ubuntu / Debian | apt |
| Fedora / RHEL / CentOS | dnf / yum |
| Arch Linux | pacman |
| macOS | brew |

Requires bash 4.0 or later. Modules are silently skipped when the relevant command is not installed (e.g. Docker module is skipped if Docker is not present).

---

## Contributing

Pull requests are welcome. If you want to add a new cleanup module, add a `clean_*` function to `cleanux.sh` and a corresponding entry in `cleanux.conf`.

Run ShellCheck before submitting:

```bash
shellcheck cleanux.sh
```

---

## License

MIT © [Marco Barca](https://github.com/marcobarca)
