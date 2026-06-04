<div align="center">

```
   ___  __    ____  ___   _  ____  ____  _  _  _  _ 
  / __)(  )  ( ___)/ __) / \(_  _)( ___)(  )( \/ )( )
 ( (__  )(__  )__) \__ \(  ) )(    )__)  )(  )  ( \/ 
  \___)(____)(____)(____(\_/)(__)  (____)(__)(__)(_)(_)
```

**One command to free gigabytes on any Linux server.**

[![ShellCheck](https://github.com/marcobarca/cleanux/actions/workflows/shellcheck.yml/badge.svg)](https://github.com/marcobarca/cleanux/actions/workflows/shellcheck.yml)
![Version](https://img.shields.io/badge/version-2.0.0-blue)
![License](https://img.shields.io/badge/license-MIT-green)
![Platform](https://img.shields.io/badge/platform-Linux%20%7C%20macOS-lightgrey)

</div>

---

Docker build cache alone can silently eat **50+ GB per week** on an active dev or homelab server. cleanux automates the safe cleanup — and leaves the risky parts opt-in.

```
$ sudo cleanux --dry-run

DRY RUN — no changes will be made

Docker
  TYPE             TOTAL     ACTIVE    SIZE      RECLAIMABLE
  Build Cache      1266      0         58.84GB   54.83GB
  Images           17        10        63.26GB   58.35GB (92%)
  Containers       14        14        3.73MB    0B

Journal logs
  Archived and active journals take up 623.4M in the file system.
  [dry-run] would run: journalctl --vacuum-time=14d

Dev caches
  npm cache (~1.2G) in /home/user...
  pip cache (~340M)...

Temp files (/tmp older than 7d)
  10 items would be removed from /tmp

────────────────────────────────
 Disk usage: 94% used  |  5.9G free
────────────────────────────────
```

---

## Install

```bash
curl -fsSL https://raw.githubusercontent.com/marcobarca/cleanux/main/install.sh | sudo bash
```

The installer copies the script to `/usr/local/bin/cleanux`, writes a default config to `/etc/cleanux.conf`, and optionally sets up a weekly cron job.

Or install manually:

```bash
git clone https://github.com/marcobarca/cleanux
cd cleanux && sudo bash install.sh
```

---

## Usage

```bash
sudo cleanux --dry-run       # preview what would be freed — no changes made
sudo cleanux                 # run with safe defaults
sudo cleanux --all           # enable every opt-in module
sudo cleanux --interactive   # choose modules from a menu
sudo cleanux --since 30      # only clean items older than 30 days
sudo cleanux -q              # silent mode — for cron
```

---

## What it cleans

| Module | On by default | Notes |
|---|:---:|---|
| Docker build cache | ✅ | Largest win — fully safe to remove |
| Docker stopped containers | ✅ | |
| Docker dangling images | ✅ | Untagged/intermediate layers only |
| Docker unused volumes | ❌ | `--enable-volumes` — opt-in, check first |
| Journal logs | ✅ | Keeps last 14 days (configurable) |
| APT / dnf / pacman / brew cache | ✅ | Downloaded package files |
| APT autoremove | ❌ | `--enable-autoremove` |
| npm / yarn / pnpm cache | ✅ | |
| pip cache | ✅ | |
| Cargo registry cache | ❌ | `--enable-cargo` — rebuilds are slow |
| Go build cache | ❌ | `--enable-go` — rebuilds are slow |
| Snap old revisions | ✅ | Disabled revisions only |
| Core dumps | ✅ | `/var/crash`, `core.*` files |
| `/tmp` old files | ✅ | Files not accessed in 7+ days |
| Thumbnail cache | ❌ | `--enable-thumbnails` — desktop only |
| Brew bundle cleanup | ✅ | macOS only, requires `Brewfile` |

---

## Scheduling

**One command to install the schedule:**

```bash
sudo cleanux --schedule                  # weekly, Sunday at 03:00 (default)
sudo cleanux --schedule "0 2 * * *"      # daily at 02:00
```

**Or use a systemd timer** (more modern, better logging):

```bash
sudo cleanux --systemd
systemctl status cleanux.timer
```

---

## Configuration

cleanux reads `/etc/cleanux.conf` on every run. Copy the default and adjust:

```bash
# /etc/cleanux.conf

JOURNAL_KEEP_DAYS=14      # days of logs to keep
DOCKER_VOLUMES=false      # enable only if you're sure containers won't restart
APT_AUTOREMOVE=false
CARGO_CACHE=false
GO_CACHE=false

DISK_THRESHOLD=80         # skip run if disk usage is below N% (0 = always run)
LOG_FILE="/var/log/cleanux.log"
LOG_MAX_MB=10             # auto-rotate log at this size

# Notifications (Slack, Discord, or generic webhook)
WEBHOOK_URL="https://hooks.slack.com/services/..."
NOTIFY_EMAIL="you@example.com"

# HTML report saved after each run
HTML_REPORT=true
HTML_REPORT_PATH="/var/log/cleanux-report.html"

# Clean dev caches for every user under /home
ALL_USERS=false
```

---

## Notifications

After each run cleanux can push a summary to Slack, Discord, or any webhook, and optionally send an email.

**Slack / Discord:**
```bash
# In /etc/cleanux.conf
WEBHOOK_URL="https://hooks.slack.com/services/T.../B.../..."
```

**Email** (requires `mail` to be configured on the system):
```bash
NOTIFY_EMAIL="ops@yourcompany.com"
```

The message includes hostname, total space freed, and current disk usage.

---

## Plugins

Drop any `.sh` file into `/etc/cleanux.d/` to add custom cleanup modules. Files are sourced automatically before the run — no need to modify the main script.

```bash
# /etc/cleanux.d/myapp.sh

clean_myapp() {
  echo -e "\nMyApp"
  info "Clearing render cache..."
  rm -rf /var/myapp/cache/renders/*
  ok "Render cache cleared"
}
```

Any function named `clean_*` in a plugin will be visible to the main script. You can also override config variables from a plugin file.

---

## Options reference

```
Commands:
  --schedule [CRON]        Set up cron job (default: "0 3 * * 0" = Sunday 03:00)
  --systemd                Install and enable systemd timer

Options:
  -n, --dry-run            Show what would be cleaned — no changes made
  -i, --interactive        Select modules interactively before running
  -q, --quiet              No output (log file still written — good for cron)
  -c, --config FILE        Use a custom config file
      --all                Enable all opt-in modules
      --all-users          Clean dev caches for every user in /home
      --since DAYS         Only target files/caches older than N days
      --enable-volumes     Docker unused volumes
      --enable-autoremove  apt autoremove
      --enable-cargo       Cargo registry cache
      --enable-go          Go build cache
      --enable-thumbnails  Thumbnail cache (~/.cache/thumbnails)
      --html-report        Write an HTML report after the run
  -v, --version            Print version
  -h, --help               Show help
```

---

## Supported systems

| Distro | Package manager |
|---|---|
| Ubuntu / Debian | apt |
| Fedora / RHEL / CentOS | dnf / yum |
| Arch Linux | pacman |
| macOS | brew |

Runs on any system with `bash >= 4.0`. Docker, snap, and dev tool modules are skipped silently when the relevant command isn't installed.

---

## Logs

Every run is appended to `/var/log/cleanux.log` with timestamps. The log is automatically rotated when it exceeds `LOG_MAX_MB` (default: 10 MB).

---

## Contributing

Pull requests welcome. If you have a cleanup module that isn't covered, open an issue or submit a PR with a new `clean_*` function in `cleanux.sh`.

Before submitting, make sure ShellCheck passes:

```bash
shellcheck cleanux.sh
```

---

## License

MIT © [Marco Barca](https://github.com/marcobarca)
