# cleanux

[![ShellCheck](https://github.com/marcobarca/cleanux/actions/workflows/shellcheck.yml/badge.svg)](https://github.com/marcobarca/cleanux/actions/workflows/shellcheck.yml)
![Version](https://img.shields.io/badge/version-2.1.18-blue)
![License](https://img.shields.io/badge/license-MIT-green)

AI-driven Linux server monitor and cleanup tool. Connect it to any OpenAI-compatible model and get a full picture of what's eating your disk, what's hammering your CPU, which processes are misbehaving, and what's worth cleaning — all explained in plain language, with a chat interface to go deeper on each finding.

## Install

```bash
curl -fsSL https://raw.githubusercontent.com/marcobarca/cleanux/main/install.sh | sudo bash
```

Run `cleanux` to open the interactive menu.

## AI scan

cleanux connects to any OpenAI-compatible endpoint, runs a live analysis of your system, and returns a ranked list of recommendations — each with a detailed explanation of what it found and why it matters.

Two scan modes:

- **AI disk scan** — analyzes storage: large files, Docker build cache, journal logs, package caches, dev tool caches (npm, pip, Cargo…), snap revisions, temp files
- **AI health scan** — analyzes runtime: CPU/memory load, heavy processes, zombie processes, systemd service anomalies, open file descriptors

Each recommendation shows a severity badge, a summary, and a full explanation. Press `c` on any item to open a chat and ask follow-up questions — the AI has full context of what it found on your machine.

### Setup

Configure from the TUI → **Configure → AI**, or edit `/etc/cleanux.conf`:

```bash
AI_ENDPOINT="https://api.openai.com/v1"   # or http://localhost:11434/v1 for Ollama
AI_API_KEY="sk-..."                        # leave empty for local models
AI_MODEL="gpt-4o-mini"
```

Azure OpenAI is supported — set the endpoint to your Azure resource URL and the model to your deployment name.

Multiple endpoints can be saved as named profiles and switched from the TUI.

Requires `python3`.

```bash
cleanux --ai-scan          # disk analysis
cleanux --ai-health-scan   # health analysis
```

## Manual cleanup

For when you want to run a targeted cleanup without the AI:

- **Docker** — build cache, stopped containers, dangling images, unused volumes *(opt-in)*
- **Journal logs** — entries older than 14 days
- **Package manager** — APT / dnf / pacman / brew cache, autoremove *(opt-in)*
- **Dev caches** — npm, yarn, pnpm, pip, Cargo *(opt-in)*, Go *(opt-in)*
- **Snap** — old disabled revisions
- **Core dumps** — `/var/crash`, `core.*` files
- **Temp files** — `/tmp` entries not accessed in 7+ days
- **Thumbnail cache** *(opt-in)* — `~/.cache/thumbnails`

## Filesystem scan

The **Scan filesystem** option performs an exploratory scan and groups findings into categories (large files, old logs, orphaned caches, etc.). Each category shows a file list with details before asking for confirmation — nothing is deleted without explicit approval.

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
