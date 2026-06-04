# cleanux

Periodic server cleanup tool for Linux. Frees disk space by pruning Docker build cache, containers, images, journal logs, and package manager caches.

## Why

On active dev/homelab servers, Docker build cache alone can eat **50+ GB per week**. `cleanux` automates the safe parts and leaves the risky ones opt-in.

## Install

```bash
curl -fsSL https://raw.githubusercontent.com/YOUR_USERNAME/cleanux/main/install.sh | sudo bash
```

Or clone and install locally:

```bash
git clone https://github.com/YOUR_USERNAME/cleanux
cd cleanux
sudo bash install.sh
```

## Usage

```bash
# Preview what would be freed (no changes made)
cleanux --dry-run

# Run cleanup
sudo cleanux

# Include Docker volumes and apt autoremove
sudo cleanux --enable-volumes --enable-autoremove

# Silent mode (for cron)
sudo cleanux -q
```

## What it cleans

| Module | Default | Notes |
|---|---|---|
| Docker build cache | ✅ | Largest win, fully safe |
| Docker stopped containers | ✅ | Safe |
| Docker dangling images | ✅ | Untagged layers only |
| Docker unused volumes | ❌ opt-in | Enable with `--enable-volumes` |
| Journal logs | ✅ | Keeps last 14 days |
| APT / dnf / pacman cache | ✅ | Downloaded packages cache |
| APT autoremove | ❌ opt-in | Enable with `--enable-autoremove` |

## Configuration

Edit `/etc/cleanux.conf` to override defaults:

```bash
JOURNAL_KEEP_DAYS=14
DOCKER_VOLUMES=false
APT_AUTOREMOVE=false
DISK_THRESHOLD=80   # only run if disk >= 80% full
LOG_FILE="/var/log/cleanux.log"
```

## Cron

The installer sets up a weekly cron at Sunday 03:00. To change the schedule:

```bash
# Edit /etc/cron.d/cleanux
# Format: minute hour day month weekday user command
0 3 * * 0 root /usr/local/bin/cleanux -q
```

## Supported systems

- Ubuntu / Debian (apt)
- Fedora / RHEL / CentOS (dnf / yum)
- Arch Linux (pacman)
- macOS (brew)

## Log

Each run is logged to `/var/log/cleanux.log`.

## License

MIT
