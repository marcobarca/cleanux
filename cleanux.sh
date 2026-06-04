#!/usr/bin/env bash
# cleanux — periodic server cleanup tool
# https://github.com/marcobarca/cleanux

set -euo pipefail

readonly VERSION="1.1.0"
readonly SCRIPT_NAME="cleanux"

# ── Defaults (override via config file) ───────────────────────────────────────
# Docker
DOCKER_BUILDER=true
DOCKER_CONTAINERS=true
DOCKER_IMAGES=true        # dangling/untagged only
DOCKER_VOLUMES=false      # opt-in: risky if containers are temporarily stopped
# System logs
JOURNAL_KEEP_DAYS=14
# Package manager
APT_CLEAN=true
APT_AUTOREMOVE=false      # opt-in
# Dev caches
NPM_CACHE=true
PIP_CACHE=true
CARGO_CACHE=false         # opt-in: slow to rebuild
GO_CACHE=false            # opt-in: slow to rebuild
# System
SNAP_REVISIONS=true       # remove disabled snap revisions
CORE_DUMPS=true           # remove /var/crash and core.* files
TMP_MAX_DAYS=7            # remove /tmp files older than N days (0 = skip)
# Desktop
THUMBNAIL_CACHE=false     # opt-in: desktop only
# General
DISK_THRESHOLD=0          # 0 = always run; N = skip if disk usage < N%
LOG_FILE="/var/log/cleanux.log"

# ── Runtime flags ─────────────────────────────────────────────────────────────
DRY_RUN=false
QUIET=false
CONF_FILE="/etc/cleanux.conf"

# ── Colors (disabled when not a tty) ──────────────────────────────────────────
if [[ -t 1 ]]; then
  RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
  BLUE='\033[0;34m'; BOLD='\033[1m'; DIM='\033[2m'; NC='\033[0m'
else
  RED=''; GREEN=''; YELLOW=''; BLUE=''; BOLD=''; DIM=''; NC=''
fi

# ── Logging ───────────────────────────────────────────────────────────────────
log()  { echo -e "${DIM}[$(date '+%Y-%m-%d %H:%M:%S')]${NC} $*" | tee -a "$LOG_FILE"; }
info() { [[ "$QUIET" == false ]] && echo -e "${BLUE}▸${NC} $*"; }
ok()   { [[ "$QUIET" == false ]] && echo -e "${GREEN}✔${NC} $*"; }
warn() { echo -e "${YELLOW}⚠${NC}  $*"; }
dry()  { echo -e "${DIM}  [dry-run] would run:${NC} $*"; }

# ── Helpers ───────────────────────────────────────────────────────────────────
disk_used_pct() { df / | awk 'NR==2 {gsub(/%/,"",$5); print $5}'; }
disk_free_human() { df -h / | awk 'NR==2 {print $4}'; }
has_cmd() { command -v "$1" &>/dev/null; }

dir_size() {
  du -sh "$1" 2>/dev/null | cut -f1 || echo "?"
}

run_or_dry() {
  local desc="$1"; shift
  if [[ "$DRY_RUN" == true ]]; then
    dry "$desc → $*"
  else
    log "$desc"
    "$@" >> "$LOG_FILE" 2>&1 || warn "$desc failed (see $LOG_FILE)"
  fi
}

detect_pkg_manager() {
  if has_cmd apt-get;    then echo "apt"
  elif has_cmd dnf;      then echo "dnf"
  elif has_cmd yum;      then echo "yum"
  elif has_cmd pacman;   then echo "pacman"
  elif has_cmd brew;     then echo "brew"
  else                        echo "unknown"
  fi
}

# ── Cleanup modules ───────────────────────────────────────────────────────────

clean_docker() {
  if ! has_cmd docker; then return; fi

  local before after freed
  before=$(df / | awk 'NR==2 {print $3}')
  echo -e "\n${BOLD}Docker${NC}"

  if [[ "$DRY_RUN" == true ]]; then
    docker system df
    return
  fi

  [[ "$DOCKER_BUILDER" == true ]]    && { info "Pruning build cache...";       run_or_dry "docker builder prune"    docker builder prune -f;    ok "Build cache pruned"; }
  [[ "$DOCKER_CONTAINERS" == true ]] && { info "Removing stopped containers..."; run_or_dry "docker container prune" docker container prune -f; ok "Stopped containers removed"; }
  [[ "$DOCKER_IMAGES" == true ]]     && { info "Removing dangling images...";  run_or_dry "docker image prune"      docker image prune -f;      ok "Dangling images removed"; }
  [[ "$DOCKER_VOLUMES" == true ]]    && { info "Removing unused volumes...";   run_or_dry "docker volume prune"     docker volume prune -f;     ok "Unused volumes removed"; }

  after=$(df / | awk 'NR==2 {print $3}')
  freed=$(( after - before ))
  (( freed > 0 )) && ok "Docker freed: $(numfmt --to=iec $((freed * 1024)) 2>/dev/null || echo "${freed}K")"
}

clean_journal() {
  if ! has_cmd journalctl; then return; fi

  echo -e "\n${BOLD}Journal logs${NC}"

  if [[ "$DRY_RUN" == true ]]; then
    journalctl --disk-usage
    dry "journalctl --vacuum-time=${JOURNAL_KEEP_DAYS}d"
    return
  fi

  info "Vacuuming journal (keeping last ${JOURNAL_KEEP_DAYS} days)..."
  run_or_dry "journalctl vacuum" journalctl --vacuum-time="${JOURNAL_KEEP_DAYS}d"
  ok "Journal trimmed"
}

clean_packages() {
  local mgr
  mgr=$(detect_pkg_manager)
  echo -e "\n${BOLD}Package manager ($mgr)${NC}"

  case "$mgr" in
    apt)
      if [[ "$APT_CLEAN" == true ]]; then
        info "Cleaning APT cache..."
        run_or_dry "apt-get clean" apt-get clean -qq
        [[ "$DRY_RUN" == false ]] && ok "APT cache cleared"
      fi
      if [[ "$APT_AUTOREMOVE" == true ]]; then
        info "Removing unused packages..."
        run_or_dry "apt-get autoremove" apt-get autoremove -y -qq
        [[ "$DRY_RUN" == false ]] && ok "Unused packages removed"
      fi
      ;;
    dnf|yum)
      info "Cleaning $mgr cache..."
      run_or_dry "$mgr clean" "$mgr" clean all -q
      [[ "$DRY_RUN" == false ]] && ok "$mgr cache cleared"
      ;;
    pacman)
      info "Cleaning pacman cache (keep last 2 versions)..."
      if has_cmd paccache; then run_or_dry "paccache" paccache -rk2
      else run_or_dry "pacman -Sc" pacman -Sc --noconfirm; fi
      [[ "$DRY_RUN" == false ]] && ok "Pacman cache cleared"
      ;;
    brew)
      info "Running brew cleanup..."
      run_or_dry "brew cleanup" brew cleanup --prune=all
      [[ "$DRY_RUN" == false ]] && ok "Homebrew cache cleared"
      ;;
    *) warn "No supported package manager found, skipping." ;;
  esac
}

clean_dev_caches() {
  local found=false

  # Check if any dev tool is present
  for cmd in npm yarn pnpm pip pip3 cargo go; do
    has_cmd "$cmd" && found=true && break
  done
  [[ "$found" == false ]] && return

  echo -e "\n${BOLD}Dev caches${NC}"

  # npm
  if [[ "$NPM_CACHE" == true ]] && has_cmd npm; then
    local npm_size; npm_size=$(dir_size "$(npm config get cache 2>/dev/null)")
    info "Cleaning npm cache (~${npm_size})..."
    run_or_dry "npm cache clean" npm cache clean --force
    [[ "$DRY_RUN" == false ]] && ok "npm cache cleared"
  fi

  # yarn
  if [[ "$NPM_CACHE" == true ]] && has_cmd yarn; then
    local yarn_dir; yarn_dir=$(yarn cache dir 2>/dev/null || echo "")
    if [[ -n "$yarn_dir" ]]; then
      local yarn_size; yarn_size=$(dir_size "$yarn_dir")
      info "Cleaning yarn cache (~${yarn_size})..."
      run_or_dry "yarn cache clean" yarn cache clean --silent
      [[ "$DRY_RUN" == false ]] && ok "yarn cache cleared"
    fi
  fi

  # pnpm
  if [[ "$NPM_CACHE" == true ]] && has_cmd pnpm; then
    info "Pruning pnpm store..."
    run_or_dry "pnpm store prune" pnpm store prune
    [[ "$DRY_RUN" == false ]] && ok "pnpm store pruned"
  fi

  # pip
  if [[ "$PIP_CACHE" == true ]]; then
    local pip_cmd=""
    has_cmd pip3 && pip_cmd="pip3"
    has_cmd pip  && pip_cmd="pip"
    if [[ -n "$pip_cmd" ]]; then
      local pip_size; pip_size=$(dir_size "${HOME}/.cache/pip")
      info "Cleaning pip cache (~${pip_size})..."
      run_or_dry "pip cache purge" "$pip_cmd" cache purge
      [[ "$DRY_RUN" == false ]] && ok "pip cache cleared"
    fi
  fi

  # cargo
  if [[ "$CARGO_CACHE" == true ]] && [[ -d "${HOME}/.cargo/registry" ]]; then
    local cargo_size; cargo_size=$(dir_size "${HOME}/.cargo/registry/cache")
    info "Cleaning cargo registry cache (~${cargo_size})..."
    if [[ "$DRY_RUN" == true ]]; then
      dry "rm -rf ~/.cargo/registry/cache ~/.cargo/registry/src"
    else
      rm -rf "${HOME}/.cargo/registry/cache" "${HOME}/.cargo/registry/src" 2>/dev/null || true
      ok "cargo registry cache cleared"
    fi
  fi

  # go
  if [[ "$GO_CACHE" == true ]] && has_cmd go; then
    local go_size; go_size=$(dir_size "$(go env GOCACHE 2>/dev/null)")
    info "Cleaning Go build cache (~${go_size})..."
    run_or_dry "go clean -cache" go clean -cache
    [[ "$DRY_RUN" == false ]] && ok "Go build cache cleared"
  fi
}

clean_snap() {
  if ! has_cmd snap; then return; fi

  local disabled
  disabled=$(snap list --all 2>/dev/null | awk 'NR>1 && /disabled/ {print $1, $3}')
  [[ -z "$disabled" ]] && return

  echo -e "\n${BOLD}Snap old revisions${NC}"

  if [[ "$DRY_RUN" == true ]]; then
    echo "$disabled" | while read -r name rev; do
      dry "snap remove $name --revision=$rev"
    done
    return
  fi

  info "Removing disabled snap revisions..."
  echo "$disabled" | while read -r name rev; do
    snap remove "$name" --revision="$rev" >> "$LOG_FILE" 2>&1 && ok "Removed $name rev.$rev" || warn "Failed: $name rev.$rev"
  done
}

clean_core_dumps() {
  if [[ "$CORE_DUMPS" == false ]]; then return; fi

  local found=false
  [[ -d /var/crash ]] && compgen -G "/var/crash/*" > /dev/null 2>&1 && found=true
  compgen -G "/tmp/core*" > /dev/null 2>&1 && found=true
  compgen -G "/var/core*" > /dev/null 2>&1 && found=true
  [[ "$found" == false ]] && return

  echo -e "\n${BOLD}Core dumps${NC}"

  if [[ "$DRY_RUN" == true ]]; then
    dry "rm -f /var/crash/* /tmp/core* /var/core*"
    return
  fi

  info "Removing core dumps..."
  rm -f /var/crash/* /tmp/core* /var/core* 2>/dev/null || true
  ok "Core dumps removed"
}

clean_tmp() {
  if (( TMP_MAX_DAYS == 0 )); then return; fi

  echo -e "\n${BOLD}Temp files (/tmp older than ${TMP_MAX_DAYS}d)${NC}"

  if [[ "$DRY_RUN" == true ]]; then
    local count
    count=$(find /tmp -maxdepth 1 -not -name "." -atime +"${TMP_MAX_DAYS}" 2>/dev/null | wc -l)
    info "${count} items would be removed from /tmp"
    return
  fi

  info "Cleaning old temp files..."
  find /tmp -maxdepth 1 -not -name "." -atime +"${TMP_MAX_DAYS}" -exec rm -rf {} + 2>/dev/null || true
  ok "/tmp cleaned"
}

clean_thumbnails() {
  if [[ "$THUMBNAIL_CACHE" == false ]]; then return; fi
  if [[ ! -d "${HOME}/.cache/thumbnails" ]]; then return; fi

  local size; size=$(dir_size "${HOME}/.cache/thumbnails")
  echo -e "\n${BOLD}Thumbnail cache${NC}"

  if [[ "$DRY_RUN" == true ]]; then
    dry "rm -rf ~/.cache/thumbnails/* (~${size})"
    return
  fi

  info "Clearing thumbnail cache (~${size})..."
  rm -rf "${HOME}/.cache/thumbnails/normal" "${HOME}/.cache/thumbnails/large" 2>/dev/null || true
  ok "Thumbnail cache cleared"
}

# ── Summary ───────────────────────────────────────────────────────────────────
print_summary() {
  local pct free
  pct=$(disk_used_pct)
  free=$(disk_free_human)

  echo -e "\n${BOLD}────────────────────────────────${NC}"
  if (( pct >= 90 )); then
    echo -e " Disk usage: ${RED}${BOLD}${pct}%${NC} used  |  ${free} free"
  elif (( pct >= 75 )); then
    echo -e " Disk usage: ${YELLOW}${BOLD}${pct}%${NC} used  |  ${free} free"
  else
    echo -e " Disk usage: ${GREEN}${BOLD}${pct}%${NC} used  |  ${free} free"
  fi
  echo -e "${BOLD}────────────────────────────────${NC}\n"
}

# ── Argument parsing ──────────────────────────────────────────────────────────
usage() {
  cat <<EOF
${BOLD}cleanux${NC} v${VERSION} — server cleanup tool

Usage: cleanux [options]

Options:
  -n, --dry-run            Show what would be cleaned without doing anything
  -q, --quiet              Suppress output (log file still written)
  -c, --config FILE        Use custom config file (default: /etc/cleanux.conf)
      --enable-volumes     Also prune unused Docker volumes
      --enable-autoremove  Also run apt autoremove
      --enable-cargo       Also clean cargo registry cache
      --enable-go          Also clean Go module/build cache
      --enable-thumbnails  Also clear thumbnail cache
  -v, --version            Print version
  -h, --help               Show this help

Config file: ${CONF_FILE}
Log file:    ${LOG_FILE}

Examples:
  cleanux --dry-run              # preview what would be freed
  cleanux --enable-volumes       # include Docker volumes
  cleanux --enable-cargo --enable-go  # include all dev caches
  cleanux -q                     # silent mode (cron-friendly)
EOF
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -n|--dry-run)            DRY_RUN=true ;;
      -q|--quiet)              QUIET=true ;;
      -c|--config)             CONF_FILE="$2"; shift ;;
      --enable-volumes)        DOCKER_VOLUMES=true ;;
      --enable-autoremove)     APT_AUTOREMOVE=true ;;
      --enable-cargo)          CARGO_CACHE=true ;;
      --enable-go)             GO_CACHE=true ;;
      --enable-thumbnails)     THUMBNAIL_CACHE=true ;;
      -v|--version)            echo "cleanux $VERSION"; exit 0 ;;
      -h|--help)               usage; exit 0 ;;
      *) warn "Unknown option: $1"; usage; exit 1 ;;
    esac
    shift
  done
}

# ── Main ──────────────────────────────────────────────────────────────────────
main() {
  parse_args "$@"

  if [[ -f "$CONF_FILE" ]]; then
    # shellcheck source=/dev/null
    source "$CONF_FILE"
  fi

  touch "$LOG_FILE" 2>/dev/null || LOG_FILE="/tmp/cleanux.log"

  if [[ "$DRY_RUN" == true ]]; then
    echo -e "\n${YELLOW}${BOLD}DRY RUN — no changes will be made${NC}\n"
  else
    echo -e "\n${BOLD}cleanux${NC} v${VERSION} — $(date '+%Y-%m-%d %H:%M:%S')"
    log "=== cleanux started ==="
  fi

  if (( DISK_THRESHOLD > 0 )); then
    local pct
    pct=$(disk_used_pct)
    if (( pct < DISK_THRESHOLD )); then
      info "Disk at ${pct}% (threshold: ${DISK_THRESHOLD}%) — nothing to do."
      exit 0
    fi
  fi

  clean_docker
  clean_journal
  clean_packages
  clean_dev_caches
  clean_snap
  clean_core_dumps
  clean_tmp
  clean_thumbnails
  print_summary

  if [[ "$DRY_RUN" == false ]]; then log "=== cleanux done ==="; fi
}

main "$@"
