# cleanux

[![ShellCheck](https://github.com/marcobarca/cleanux/actions/workflows/shellcheck.yml/badge.svg)](https://github.com/marcobarca/cleanux/actions/workflows/shellcheck.yml)
![Version](https://img.shields.io/badge/version-2.1.7-blue)
![License](https://img.shields.io/badge/license-MIT-green)

Interactive cleanup tool for Linux servers and dev machines. Removes Docker build cache, journal logs, package manager caches, dev tool caches, snap old revisions, core dumps, and stale temp files.

## Install

```bash
curl -fsSL https://raw.githubusercontent.com/marcobarca/cleanux/main/install.sh | sudo bash
```

Run `cleanux` to open the interactive menu.

## What it cleans

- **Docker** — build cache, stopped containers, dangling images, unused volumes *(opt-in)*
- **Journal logs** — entries older than 14 days
- **Package manager** — APT / dnf / pacman / brew cache, autoremove *(opt-in)*
- **Dev caches** — npm, yarn, pnpm, pip, Cargo *(opt-in)*, Go *(opt-in)*
- **Snap** — old disabled revisions
- **Core dumps** — `/var/crash`, `core.*` files
- **Temp files** — `/tmp` entries not accessed in 7+ days
- **Thumbnail cache** *(opt-in)* — `~/.cache/thumbnails`

## Filesystem scan

The **Scan filesystem** option in the TUI performs an exploratory scan and groups findings into categories (large files, old logs, orphaned caches, etc.). Each category shows a file list with details before asking for confirmation — nothing is deleted without explicit approval.

## AI scan

cleanux can connect to any OpenAI-compatible endpoint and suggest what to clean up based on live system data.

Configure from the TUI → **Configure → AI**, or edit `/etc/cleanux.conf`:

```bash
AI_ENDPOINT="https://api.openai.com/v1"   # or http://localhost:11434/v1 for Ollama
AI_API_KEY="sk-..."                        # leave empty for local models
AI_MODEL="gpt-4o-mini"
```

Multiple endpoints can be saved as named profiles and switched from the TUI. The AI receives disk usage, large files, Docker stats, log sizes, and dev cache info — it only produces recommendations, nothing is deleted automatically.

Requires `python3`.

```bash
cleanux --ai-scan
```

## Non-interactive use

```bash
sudo cleanux --dry-run     # preview without making changes
sudo cleanux -q            # silent run, for cron
sudo cleanux --all         # enable all opt-in modules
sudo cleanux --since 30    # only clean items older than 30 days
sudo cleanux --schedule    # set up weekly cron (Sunday 03:00)
sudo cleanux --systemd     # install systemd timer instead
sudo cleanux --update      # update cleanux to the latest version
```

## Plugins

Drop a `.sh` file in `/etc/cleanux.d/` to add custom cleanup steps. It will be sourced automatically.

## License

MIT © [Marco Barca](https://github.com/marcobarca)
