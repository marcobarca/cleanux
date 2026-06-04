# cleanux

[![ShellCheck](https://github.com/marcobarca/cleanux/actions/workflows/shellcheck.yml/badge.svg)](https://github.com/marcobarca/cleanux/actions/workflows/shellcheck.yml)
![Version](https://img.shields.io/badge/version-2.0.0-blue)
![License](https://img.shields.io/badge/license-MIT-green)

Bash script that removes temporary files and caches that accumulate on Linux servers and development machines: Docker build cache, journal logs, package manager caches, dev tool caches, snap old revisions, core dumps, and old temp files.

## Install

```bash
curl -fsSL https://raw.githubusercontent.com/marcobarca/cleanux/main/install.sh | sudo bash
```

Then run `cleanux` to open the interactive menu.

## What it deletes

- **Docker** — build cache, stopped containers, dangling images, unused volumes *(opt-in)*
- **Journal logs** — entries older than 14 days
- **Package manager** — APT / dnf / pacman / brew cache, autoremove *(opt-in)*
- **Dev caches** — npm, yarn, pnpm, pip, Cargo *(opt-in)*, Go *(opt-in)*
- **Snap** — old disabled revisions
- **Core dumps** — `/var/crash`, `core.*` files
- **Temp files** — `/tmp` entries not accessed in 7+ days
- **Thumbnail cache** *(opt-in)* — `~/.cache/thumbnails`

## Configuration

Edit `/etc/cleanux.conf` to change defaults. All opt-in modules are disabled by default and can be enabled from the interactive menu or via flags.

## Non-interactive use

```bash
sudo cleanux --dry-run     # preview without making changes
sudo cleanux -q            # silent run, for cron
sudo cleanux --all         # enable all opt-in modules
sudo cleanux --since 30    # only clean items older than 30 days
sudo cleanux --schedule    # set up weekly cron (Sunday 03:00)
sudo cleanux --systemd     # install systemd timer instead
```

## Plugins

Drop a `.sh` file in `/etc/cleanux.d/` to add custom cleanup steps. It will be sourced automatically.

## License

MIT © [Marco Barca](https://github.com/marcobarca)
