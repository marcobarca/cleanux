#!/usr/bin/env bash
# cleanux — periodic server cleanup tool
# https://github.com/marcobarca/cleanux

set -euo pipefail

readonly VERSION="2.0.0"

# ── Defaults (override via config file) ───────────────────────────────────────
# Docker
DOCKER_BUILDER=true
DOCKER_CONTAINERS=true
DOCKER_IMAGES=true
DOCKER_VOLUMES=false
# Logs
JOURNAL_KEEP_DAYS=14
# Packages
APT_CLEAN=true
APT_AUTOREMOVE=false
# Dev caches
NPM_CACHE=true
PIP_CACHE=true
CARGO_CACHE=false
GO_CACHE=false
# System
SNAP_REVISIONS=true
CORE_DUMPS=true
TMP_MAX_DAYS=7
# Desktop
THUMBNAIL_CACHE=false
# Notifications
WEBHOOK_URL=""          # Slack/Discord/generic webhook URL
NOTIFY_EMAIL=""         # email address for reports (requires mail command)
# Reports
HTML_REPORT=false
HTML_REPORT_PATH="/var/log/cleanux-report.html"
# Log
LOG_FILE="/var/log/cleanux.log"
LOG_MAX_MB=10           # rotate log when it exceeds N MB
# Misc
DISK_THRESHOLD=0
ALL_USERS=false         # clean dev caches for all users in /home

# ── Runtime flags ─────────────────────────────────────────────────────────────
DRY_RUN=false
QUIET=false
INTERACTIVE=false
SINCE_DAYS=0            # override age-based cleanup (0 = use module defaults)
CONF_FILE="/etc/cleanux.conf"

# ── Colors ────────────────────────────────────────────────────────────────────
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
has_cmd() { command -v "$1" &>/dev/null; }

# ── Freed-space tracking ──────────────────────────────────────────────────────
_DISK_START=0
_MODULE_START=0
FREED_TOTAL=0
declare -A MODULE_FREED=()

disk_kb() { df / | awk 'NR==2 {print $3}'; }

module_start() { _MODULE_START=$(disk_kb); }

module_end() {
  local name="$1"
  local after; after=$(disk_kb)
  local freed=$(( (after - _MODULE_START) * 1024 ))
  if (( freed > 0 )); then
    MODULE_FREED["$name"]=$freed
    FREED_TOTAL=$(( FREED_TOTAL + freed ))
  fi
}

human_bytes() {
  local bytes=$1
  if (( bytes >= 1073741824 )); then printf "%.1f GB" "$(echo "scale=1; $bytes/1073741824" | bc)"
  elif (( bytes >= 1048576 )); then printf "%.1f MB" "$(echo "scale=1; $bytes/1048576" | bc)"
  else printf "%d KB" "$(( bytes / 1024 ))"; fi
}

dir_size() { du -sh "$1" 2>/dev/null | cut -f1 || echo "?"; }
disk_used_pct() { df / | awk 'NR==2 {gsub(/%/,"",$5); print $5}'; }
disk_free_human() { df -h / | awk 'NR==2 {print $4}'; }

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

# ── Log rotation ──────────────────────────────────────────────────────────────
rotate_log() {
  [[ ! -f "$LOG_FILE" ]] && return
  local size_mb
  size_mb=$(du -m "$LOG_FILE" 2>/dev/null | cut -f1 || echo 0)
  if (( size_mb >= LOG_MAX_MB )); then
    mv "$LOG_FILE" "${LOG_FILE}.1"
    touch "$LOG_FILE"
  fi
}

# ── Plugin loader ─────────────────────────────────────────────────────────────
load_plugins() {
  local dir="/etc/cleanux.d"
  [[ -d "$dir" ]] || return 0
  for plugin in "$dir"/*.sh; do
    [[ -f "$plugin" ]] || continue
    # shellcheck source=/dev/null
    source "$plugin"
    info "Plugin loaded: $(basename "$plugin")"
  done
}

# ── Notifications ─────────────────────────────────────────────────────────────
notify() {
  local msg="$1"
  [[ -z "$WEBHOOK_URL" && -z "$NOTIFY_EMAIL" ]] && return

  if [[ -n "$WEBHOOK_URL" ]] && has_cmd curl; then
    local hostname; hostname=$(hostname)
    local payload="{\"text\": \"*cleanux* on \`${hostname}\`: ${msg}\"}"
    curl -s -X POST "$WEBHOOK_URL" \
      -H "Content-Type: application/json" \
      -d "$payload" >> "$LOG_FILE" 2>&1 || warn "Webhook notification failed"
  fi

  if [[ -n "$NOTIFY_EMAIL" ]] && has_cmd mail; then
    echo "$msg" | mail -s "cleanux report — $(hostname) — $(date '+%Y-%m-%d')" \
      "$NOTIFY_EMAIL" 2>/dev/null || warn "Email notification failed"
  fi
}

# ── HTML report ───────────────────────────────────────────────────────────────
generate_html_report() {
  local freed_human; freed_human=$(human_bytes "$FREED_TOTAL" 2>/dev/null || echo "${FREED_TOTAL}B")
  local disk_pct; disk_pct=$(disk_used_pct)
  local disk_free; disk_free=$(disk_free_human)
  local ts; ts=$(date '+%Y-%m-%d %H:%M:%S')

  local rows=""
  for mod in "${!MODULE_FREED[@]}"; do
    local size; size=$(human_bytes "${MODULE_FREED[$mod]}" 2>/dev/null || echo "?")
    rows+="<tr><td>${mod}</td><td>${size}</td></tr>"
  done

  cat > "$HTML_REPORT_PATH" <<HTML
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <title>cleanux report — $(hostname)</title>
  <style>
    body { font-family: monospace; background: #0d1117; color: #c9d1d9; padding: 2rem; }
    h1 { color: #58a6ff; } h2 { color: #8b949e; font-size: 1rem; }
    table { border-collapse: collapse; width: 100%; max-width: 500px; }
    th, td { padding: .5rem 1rem; text-align: left; border-bottom: 1px solid #21262d; }
    th { color: #8b949e; }
    .big { font-size: 2rem; color: #3fb950; font-weight: bold; }
    .warn { color: #d29922; } .danger { color: #f85149; }
  </style>
</head>
<body>
  <h1>🧹 cleanux v${VERSION}</h1>
  <h2>$(hostname) &mdash; ${ts}</h2>
  <p class="big">${freed_human} freed</p>
  <table>
    <tr><th>Module</th><th>Freed</th></tr>
    ${rows}
  </table>
  <br>
  <table>
    <tr><th>Disk usage after</th><td class="$(( disk_pct >= 90 )) && echo danger || (( disk_pct >= 75 )) && echo warn || echo "")">${disk_pct}% used &mdash; ${disk_free} free</td></tr>
  </table>
</body>
</html>
HTML
  ok "HTML report saved to ${HTML_REPORT_PATH}"
}

# ── Interactive mode ──────────────────────────────────────────────────────────
interactive_select() {
  echo -e "\n${BOLD}Select modules to run${NC} (toggle by number, Enter to confirm)\n"

  declare -a LABELS=(
    "Docker (build cache, containers, images)"
    "Docker volumes (opt-in)"
    "Journal logs"
    "Package manager (apt/dnf/pacman/brew)"
    "Dev caches (npm, pip, yarn, pnpm)"
    "Cargo cache (opt-in)"
    "Go cache (opt-in)"
    "Snap old revisions"
    "Core dumps"
    "Temp files /tmp"
    "Thumbnail cache (opt-in)"
  )

  # Normalize states to true/false
  local n=${#LABELS[@]}
  declare -a ENABLED=()
  ENABLED[0]=$( [[ "$DOCKER_BUILDER" == true ]]    && echo true || echo false )
  ENABLED[1]=$( [[ "$DOCKER_VOLUMES" == true ]]    && echo true || echo false )
  ENABLED[2]=true
  ENABLED[3]=$( [[ "$APT_CLEAN" == true ]]         && echo true || echo false )
  ENABLED[4]=$( [[ "$NPM_CACHE" == true ]]         && echo true || echo false )
  ENABLED[5]=$( [[ "$CARGO_CACHE" == true ]]       && echo true || echo false )
  ENABLED[6]=$( [[ "$GO_CACHE" == true ]]          && echo true || echo false )
  ENABLED[7]=$( [[ "$SNAP_REVISIONS" == true ]]    && echo true || echo false )
  ENABLED[8]=$( [[ "$CORE_DUMPS" == true ]]        && echo true || echo false )
  ENABLED[9]=$( (( TMP_MAX_DAYS > 0 ))             && echo true || echo false )
  ENABLED[10]=$( [[ "$THUMBNAIL_CACHE" == true ]]  && echo true || echo false )

  while true; do
    echo ""
    for (( i=0; i<n; i++ )); do
      local mark; [[ "${ENABLED[$i]}" == true ]] && mark="${GREEN}✓${NC}" || mark=" "
      printf "  %2d. [%b] %s\n" $(( i+1 )) "$mark" "${LABELS[$i]}"
    done
    echo ""
    read -r -p "Toggle number (or Enter to start): " choice
    [[ -z "$choice" ]] && break
    if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= n )); then
      local idx=$(( choice - 1 ))
      [[ "${ENABLED[$idx]}" == true ]] && ENABLED[$idx]=false || ENABLED[$idx]=true
    else
      warn "Invalid choice: $choice"
    fi
  done

  # Apply selections
  DOCKER_BUILDER="${ENABLED[0]}"
  DOCKER_VOLUMES="${ENABLED[1]}"
  [[ "${ENABLED[2]}" == false ]] && JOURNAL_KEEP_DAYS=0
  APT_CLEAN="${ENABLED[3]}"
  NPM_CACHE="${ENABLED[4]}"
  CARGO_CACHE="${ENABLED[5]}"
  GO_CACHE="${ENABLED[6]}"
  SNAP_REVISIONS="${ENABLED[7]}"
  CORE_DUMPS="${ENABLED[8]}"
  [[ "${ENABLED[9]}" == false ]] && TMP_MAX_DAYS=0
  THUMBNAIL_CACHE="${ENABLED[10]}"
}

# ── Setup helpers ─────────────────────────────────────────────────────────────
cmd_schedule() {
  local schedule="${1:-0 3 * * 0}"
  local bin; bin=$(command -v cleanux 2>/dev/null || echo /usr/local/bin/cleanux)
  local cron_file="/etc/cron.d/cleanux"
  echo "# cleanux — generated by cleanux --schedule" > "$cron_file"
  echo "$schedule root $bin -q" >> "$cron_file"
  chmod 644 "$cron_file"
  ok "Cron scheduled: ${BOLD}${schedule}${NC} → ${cron_file}"
}

cmd_systemd() {
  local bin; bin=$(command -v cleanux 2>/dev/null || echo /usr/local/bin/cleanux)

  cat > /etc/systemd/system/cleanux.service <<EOF
[Unit]
Description=cleanux — server cleanup
After=network.target

[Service]
Type=oneshot
ExecStart=${bin} -q
StandardOutput=journal
StandardError=journal
EOF

  cat > /etc/systemd/system/cleanux.timer <<EOF
[Unit]
Description=cleanux weekly cleanup timer

[Timer]
OnCalendar=Sun 03:00:00
Persistent=true

[Install]
WantedBy=timers.target
EOF

  systemctl daemon-reload
  systemctl enable --now cleanux.timer
  ok "systemd timer enabled — runs every Sunday at 03:00"
  ok "Check status with: ${BOLD}systemctl status cleanux.timer${NC}"
}

# ── Cleanup modules ───────────────────────────────────────────────────────────

clean_docker() {
  if ! has_cmd docker; then return; fi
  echo -e "\n${BOLD}Docker${NC}"
  module_start

  if [[ "$DRY_RUN" == true ]]; then
    docker system df
    return
  fi

  [[ "$DOCKER_BUILDER" == true ]]    && { info "Pruning build cache...";        run_or_dry "docker builder prune"    docker builder prune -f;    ok "Build cache pruned"; }
  [[ "$DOCKER_CONTAINERS" == true ]] && { info "Removing stopped containers..."; run_or_dry "docker container prune" docker container prune -f; ok "Stopped containers removed"; }
  [[ "$DOCKER_IMAGES" == true ]]     && { info "Removing dangling images...";   run_or_dry "docker image prune"      docker image prune -f;      ok "Dangling images removed"; }
  [[ "$DOCKER_VOLUMES" == true ]]    && { info "Removing unused volumes...";    run_or_dry "docker volume prune"     docker volume prune -f;     ok "Unused volumes removed"; }

  module_end "Docker"
}

clean_journal() {
  if ! has_cmd journalctl; then return; fi
  (( JOURNAL_KEEP_DAYS == 0 )) && return

  local keep_days=$JOURNAL_KEEP_DAYS
  (( SINCE_DAYS > 0 && SINCE_DAYS < keep_days )) && keep_days=$SINCE_DAYS

  echo -e "\n${BOLD}Journal logs${NC}"
  module_start

  if [[ "$DRY_RUN" == true ]]; then
    journalctl --disk-usage
    dry "journalctl --vacuum-time=${keep_days}d"
    return
  fi

  info "Vacuuming journal (keeping last ${keep_days} days)..."
  run_or_dry "journalctl vacuum" journalctl --vacuum-time="${keep_days}d"
  ok "Journal trimmed"
  module_end "Journal"
}

clean_packages() {
  local mgr; mgr=$(detect_pkg_manager)
  echo -e "\n${BOLD}Package manager ($mgr)${NC}"
  module_start

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
      info "Cleaning pacman cache..."
      if has_cmd paccache; then run_or_dry "paccache" paccache -rk2
      else run_or_dry "pacman -Sc" pacman -Sc --noconfirm; fi
      [[ "$DRY_RUN" == false ]] && ok "Pacman cache cleared"
      ;;
    brew)
      info "Running brew cleanup..."
      run_or_dry "brew cleanup" brew cleanup --prune=all
      if [[ "$DRY_RUN" == false ]]; then
        ok "Homebrew cache cleared"
        if has_cmd brew && [[ -f "Brewfile" ]]; then
          info "Removing formulae not in Brewfile..."
          run_or_dry "brew bundle cleanup" brew bundle cleanup --force
          ok "Brewfile cleanup done"
        fi
      fi
      ;;
    *) warn "No supported package manager found, skipping." ;;
  esac

  module_end "Packages"
}

_clean_dev_for_user() {
  local home_dir="$1"
  [[ -d "$home_dir" ]] || return

  if [[ "$NPM_CACHE" == true ]]; then
    if has_cmd npm; then
      local npm_cache; npm_cache=$(npm config get cache 2>/dev/null || echo "${home_dir}/.npm")
      if [[ -d "$npm_cache" ]]; then
        local sz; sz=$(dir_size "$npm_cache")
        info "npm cache (~${sz}) in ${home_dir}..."
        run_or_dry "npm cache clean" npm cache clean --force
        [[ "$DRY_RUN" == false ]] && ok "npm cache cleared"
      fi
    fi
    if has_cmd yarn; then
      local yarn_dir; yarn_dir=$(yarn cache dir 2>/dev/null || echo "")
      if [[ -n "$yarn_dir" && -d "$yarn_dir" ]]; then
        local sz; sz=$(dir_size "$yarn_dir")
        info "yarn cache (~${sz})..."
        run_or_dry "yarn cache clean" yarn cache clean --silent
        [[ "$DRY_RUN" == false ]] && ok "yarn cache cleared"
      fi
    fi
    if has_cmd pnpm; then
      info "pnpm store prune..."
      run_or_dry "pnpm store prune" pnpm store prune
      [[ "$DRY_RUN" == false ]] && ok "pnpm store pruned"
    fi
  fi

  if [[ "$PIP_CACHE" == true ]]; then
    local pip_cmd=""
    has_cmd pip3 && pip_cmd="pip3"
    has_cmd pip  && pip_cmd="pip"
    if [[ -n "$pip_cmd" ]]; then
      local sz; sz=$(dir_size "${home_dir}/.cache/pip")
      info "pip cache (~${sz})..."
      run_or_dry "pip cache purge" "$pip_cmd" cache purge
      [[ "$DRY_RUN" == false ]] && ok "pip cache cleared"
    fi
  fi

  if [[ "$CARGO_CACHE" == true && -d "${home_dir}/.cargo/registry" ]]; then
    local sz; sz=$(dir_size "${home_dir}/.cargo/registry/cache")
    info "cargo registry (~${sz})..."
    if [[ "$DRY_RUN" == true ]]; then
      dry "rm -rf ${home_dir}/.cargo/registry/cache ${home_dir}/.cargo/registry/src"
    else
      rm -rf "${home_dir}/.cargo/registry/cache" "${home_dir}/.cargo/registry/src" 2>/dev/null || true
      ok "cargo registry cleared"
    fi
  fi

  if [[ "$GO_CACHE" == true ]] && has_cmd go; then
    local gocache; gocache=$(go env GOCACHE 2>/dev/null || echo "${home_dir}/.cache/go-build")
    local sz; sz=$(dir_size "$gocache")
    info "Go build cache (~${sz})..."
    run_or_dry "go clean -cache" go clean -cache
    [[ "$DRY_RUN" == false ]] && ok "Go cache cleared"
  fi

  if [[ "$THUMBNAIL_CACHE" == true && -d "${home_dir}/.cache/thumbnails" ]]; then
    local sz; sz=$(dir_size "${home_dir}/.cache/thumbnails")
    info "Thumbnails (~${sz}) in ${home_dir}..."
    if [[ "$DRY_RUN" == true ]]; then
      dry "rm -rf ${home_dir}/.cache/thumbnails/normal ${home_dir}/.cache/thumbnails/large"
    else
      rm -rf "${home_dir}/.cache/thumbnails/normal" "${home_dir}/.cache/thumbnails/large" 2>/dev/null || true
      ok "Thumbnail cache cleared"
    fi
  fi
}

clean_dev_caches() {
  local any=false
  for cmd in npm yarn pnpm pip pip3 cargo go; do has_cmd "$cmd" && any=true && break; done
  [[ "$any" == false ]] && return

  echo -e "\n${BOLD}Dev caches${NC}"
  module_start

  if [[ "$ALL_USERS" == true ]]; then
    for user_home in /home/*/; do
      [[ -d "$user_home" ]] || continue
      info "User: ${user_home}"
      _clean_dev_for_user "$user_home"
    done
  else
    _clean_dev_for_user "$HOME"
  fi

  module_end "Dev caches"
}

clean_snap() {
  if ! has_cmd snap; then return; fi
  [[ "$SNAP_REVISIONS" == false ]] && return

  local disabled; disabled=$(snap list --all 2>/dev/null | awk 'NR>1 && /disabled/ {print $1, $3}')
  [[ -z "$disabled" ]] && return

  echo -e "\n${BOLD}Snap old revisions${NC}"
  module_start

  if [[ "$DRY_RUN" == true ]]; then
    while IFS= read -r line; do dry "snap remove $line"; done <<< "$disabled"
    return
  fi

  info "Removing disabled snap revisions..."
  while read -r name rev; do
    snap remove "$name" --revision="$rev" >> "$LOG_FILE" 2>&1 \
      && ok "Removed $name rev.$rev" \
      || warn "Failed: $name rev.$rev"
  done <<< "$disabled"

  module_end "Snap"
}

clean_core_dumps() {
  if [[ "$CORE_DUMPS" == false ]]; then return; fi

  local max_age=${SINCE_DAYS:-0}
  local find_args=()
  (( max_age > 0 )) && find_args=(-mtime +"$max_age")

  local search_dirs=(/tmp /var)
  [[ -d /var/crash ]] && search_dirs+=(/var/crash)

  local files
  files=$(find "${search_dirs[@]}" -maxdepth 2 \
    \( -name "*.crash" -o -name "core" -o -name "core.*" \) \
    "${find_args[@]}" 2>/dev/null | head -50) || true
  [[ -z "$files" ]] && return

  echo -e "\n${BOLD}Core dumps${NC}"
  module_start

  if [[ "$DRY_RUN" == true ]]; then
    echo "$files" | while IFS= read -r f; do dry "rm -f $f"; done
    return
  fi

  info "Removing core dumps..."
  echo "$files" | xargs -r rm -f 2>/dev/null || true
  ok "Core dumps removed"
  module_end "Core dumps"
}

clean_tmp() {
  local max_days=$TMP_MAX_DAYS
  (( SINCE_DAYS > 0 && SINCE_DAYS < max_days )) && max_days=$SINCE_DAYS
  (( max_days == 0 )) && return

  echo -e "\n${BOLD}Temp files (/tmp older than ${max_days}d)${NC}"
  module_start

  if [[ "$DRY_RUN" == true ]]; then
    local count; count=$(find /tmp -maxdepth 1 -not -name "." -atime +"${max_days}" 2>/dev/null | wc -l)
    info "${count} items would be removed from /tmp"
    return
  fi

  info "Cleaning old temp files..."
  find /tmp -maxdepth 1 -not -name "." -atime +"${max_days}" -exec rm -rf {} + 2>/dev/null || true
  ok "/tmp cleaned"
  module_end "Tmp"
}

# ── Summary ───────────────────────────────────────────────────────────────────
print_summary() {
  local pct; pct=$(disk_used_pct)
  local free; free=$(disk_free_human)

  echo -e "\n${BOLD}────────────────────────────────${NC}"

  if (( FREED_TOTAL > 0 )); then
    local freed_human; freed_human=$(human_bytes "$FREED_TOTAL" 2>/dev/null || echo "?")
    echo -e " Freed:      ${GREEN}${BOLD}${freed_human}${NC}"
    if [[ ${#MODULE_FREED[@]} -gt 0 ]]; then
      for mod in "${!MODULE_FREED[@]}"; do
        local sz; sz=$(human_bytes "${MODULE_FREED[$mod]}" 2>/dev/null || echo "?")
        printf "             ${DIM}%-18s %s${NC}\n" "$mod" "$sz"
      done
    fi
  fi

  if (( pct >= 90 )); then
    echo -e " Disk usage: ${RED}${BOLD}${pct}%${NC} used  |  ${free} free"
  elif (( pct >= 75 )); then
    echo -e " Disk usage: ${YELLOW}${BOLD}${pct}%${NC} used  |  ${free} free"
  else
    echo -e " Disk usage: ${GREEN}${BOLD}${pct}%${NC} used  |  ${free} free"
  fi

  echo -e "${BOLD}────────────────────────────────${NC}\n"
}

# ── Usage ─────────────────────────────────────────────────────────────────────
usage() {
  cat <<EOF
${BOLD}cleanux${NC} v${VERSION} — server cleanup tool

Usage: cleanux [options] [command]

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
  -v, --version            Print version
  -h, --help               Show this help

Examples:
  cleanux --dry-run              # preview
  cleanux --all                  # clean everything
  cleanux --interactive          # pick modules
  cleanux --since 30             # only clean items older than 30 days
  cleanux --schedule "0 2 * * 0" # schedule every Sunday at 02:00
  cleanux --systemd              # install systemd timer
  cleanux -q                     # silent (cron-friendly)
EOF
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -n|--dry-run)            DRY_RUN=true ;;
      -i|--interactive)        INTERACTIVE=true ;;
      -q|--quiet)              QUIET=true ;;
      -c|--config)             CONF_FILE="$2"; shift ;;
      --all)
        DOCKER_VOLUMES=true; APT_AUTOREMOVE=true; CARGO_CACHE=true
        GO_CACHE=true; THUMBNAIL_CACHE=true
        ;;
      --all-users)             ALL_USERS=true ;;
      --since)                 SINCE_DAYS="$2"; shift ;;
      --enable-volumes)        DOCKER_VOLUMES=true ;;
      --enable-autoremove)     APT_AUTOREMOVE=true ;;
      --enable-cargo)          CARGO_CACHE=true ;;
      --enable-go)             GO_CACHE=true ;;
      --enable-thumbnails)     THUMBNAIL_CACHE=true ;;
      --html-report)           HTML_REPORT=true ;;
      --schedule)
        [[ $# -gt 1 && ! "$2" =~ ^- ]] && { cmd_schedule "$2"; shift; } || cmd_schedule
        exit 0 ;;
      --systemd)               cmd_systemd; exit 0 ;;
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

  # shellcheck source=/dev/null
  [[ -f "$CONF_FILE" ]] && source "$CONF_FILE"

  touch "$LOG_FILE" 2>/dev/null || LOG_FILE="/tmp/cleanux.log"
  rotate_log
  load_plugins

  if [[ "$DRY_RUN" == true ]]; then
    echo -e "\n${YELLOW}${BOLD}DRY RUN — no changes will be made${NC}\n"
  else
    echo -e "\n${BOLD}cleanux${NC} v${VERSION} — $(date '+%Y-%m-%d %H:%M:%S')"
    log "=== cleanux started ==="
  fi

  if (( DISK_THRESHOLD > 0 )); then
    local pct; pct=$(disk_used_pct)
    if (( pct < DISK_THRESHOLD )); then
      info "Disk at ${pct}% (threshold: ${DISK_THRESHOLD}%) — nothing to do."
      exit 0
    fi
  fi

  [[ "$INTERACTIVE" == true ]] && interactive_select

  _DISK_START=$(disk_kb)

  clean_docker
  clean_journal
  clean_packages
  clean_dev_caches
  clean_snap
  clean_core_dumps
  clean_tmp
  print_summary

  if [[ "$DRY_RUN" == false ]]; then
    [[ "$HTML_REPORT" == true ]] && generate_html_report
    local freed_human; freed_human=$(human_bytes "$FREED_TOTAL" 2>/dev/null || echo "0 B")
    notify "Cleanup complete — freed ${freed_human} — disk at $(disk_used_pct)%"
    log "=== cleanux done — freed ${freed_human} ==="
  fi
}

main "$@"
