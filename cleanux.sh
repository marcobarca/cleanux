#!/usr/bin/env bash
# cleanux — periodic server cleanup tool
# https://github.com/YOUR_USERNAME/cleanux

set -euo pipefail

readonly VERSION="1.0.0"
readonly SCRIPT_NAME="cleanux"

# ── Defaults (override via config file) ───────────────────────────────────────
JOURNAL_KEEP_DAYS=14
DOCKER_BUILDER=true
DOCKER_CONTAINERS=true
DOCKER_IMAGES=true        # dangling/untagged only
DOCKER_VOLUMES=false      # opt-in: risky if containers are temporarily stopped
APT_CLEAN=true
APT_AUTOREMOVE=false      # opt-in
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
disk_used_pct() {
  df / | awk 'NR==2 {gsub(/%/,"",$5); print $5}'
}

disk_free_human() {
  df -h / | awk 'NR==2 {print $4}'
}

bytes_freed=0

run_or_dry() {
  # Usage: run_or_dry <description> <command...>
  local desc="$1"; shift
  if [[ "$DRY_RUN" == true ]]; then
    dry "$desc → $*"
  else
    log "$desc"
    "$@" >> "$LOG_FILE" 2>&1 || warn "$desc failed (see $LOG_FILE)"
  fi
}

has_cmd() { command -v "$1" &>/dev/null; }

# ── Package manager detection ─────────────────────────────────────────────────
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
  if ! has_cmd docker; then
    info "Docker not found, skipping."
    return
  fi

  local before after freed
  before=$(df / | awk 'NR==2 {print $3}')

  echo -e "\n${BOLD}Docker${NC}"

  if [[ "$DRY_RUN" == true ]]; then
    docker system df
    return
  fi

  if [[ "$DOCKER_BUILDER" == true ]]; then
    info "Pruning build cache..."
    run_or_dry "docker builder prune" docker builder prune -f
    ok "Build cache pruned"
  fi

  if [[ "$DOCKER_CONTAINERS" == true ]]; then
    info "Removing stopped containers..."
    run_or_dry "docker container prune" docker container prune -f
    ok "Stopped containers removed"
  fi

  if [[ "$DOCKER_IMAGES" == true ]]; then
    info "Removing dangling images..."
    run_or_dry "docker image prune" docker image prune -f
    ok "Dangling images removed"
  fi

  if [[ "$DOCKER_VOLUMES" == true ]]; then
    info "Removing unused volumes..."
    run_or_dry "docker volume prune" docker volume prune -f
    ok "Unused volumes removed"
  fi

  after=$(df / | awk 'NR==2 {print $3}')
  freed=$(( after - before ))   # in 1K blocks, can be negative due to writes
  if (( freed > 0 )); then
    ok "Docker freed: $(numfmt --to=iec $((freed * 1024)) 2>/dev/null || echo "${freed}K")"
  fi
}

clean_journal() {
  if ! has_cmd journalctl; then
    return
  fi

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
      if has_cmd paccache; then
        run_or_dry "paccache" paccache -rk2
      else
        run_or_dry "pacman -Sc" pacman -Sc --noconfirm
      fi
      [[ "$DRY_RUN" == false ]] && ok "Pacman cache cleared"
      ;;
    brew)
      info "Running brew cleanup..."
      run_or_dry "brew cleanup" brew cleanup --prune=all
      [[ "$DRY_RUN" == false ]] && ok "Homebrew cache cleared"
      ;;
    *)
      warn "No supported package manager found, skipping."
      ;;
  esac
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
  -n, --dry-run          Show what would be cleaned without doing anything
  -q, --quiet            Suppress output (log file still written)
  -c, --config FILE      Use custom config file (default: /etc/cleanux.conf)
      --enable-volumes   Also prune unused Docker volumes (opt-in)
      --enable-autoremove  Also run apt autoremove (opt-in)
  -v, --version          Print version
  -h, --help             Show this help

Config file: ${CONF_FILE}
Log file:    ${LOG_FILE}

Examples:
  cleanux --dry-run          # preview what would be freed
  cleanux --enable-volumes   # include Docker volumes
  cleanux -q                 # silent mode (cron-friendly)
EOF
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -n|--dry-run)          DRY_RUN=true ;;
      -q|--quiet)            QUIET=true ;;
      -c|--config)           CONF_FILE="$2"; shift ;;
      --enable-volumes)      DOCKER_VOLUMES=true ;;
      --enable-autoremove)   APT_AUTOREMOVE=true ;;
      -v|--version)          echo "cleanux $VERSION"; exit 0 ;;
      -h|--help)             usage; exit 0 ;;
      *) warn "Unknown option: $1"; usage; exit 1 ;;
    esac
    shift
  done
}

# ── Main ──────────────────────────────────────────────────────────────────────
main() {
  parse_args "$@"

  # Load config if it exists
  if [[ -f "$CONF_FILE" ]]; then
    # shellcheck source=/dev/null
    source "$CONF_FILE"
  fi

  # Ensure log file is writable
  touch "$LOG_FILE" 2>/dev/null || LOG_FILE="/tmp/cleanux.log"

  if [[ "$DRY_RUN" == true ]]; then
    echo -e "\n${YELLOW}${BOLD}DRY RUN — no changes will be made${NC}\n"
  else
    echo -e "\n${BOLD}cleanux${NC} v${VERSION} — $(date '+%Y-%m-%d %H:%M:%S')"
    log "=== cleanux started ==="
  fi

  # Optional threshold check
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
  print_summary

  if [[ "$DRY_RUN" == false ]]; then
    log "=== cleanux done ==="
  fi
}

main "$@"
