#!/usr/bin/env bash
# cleanux — periodic server cleanup tool
# https://github.com/marcobarca/cleanux

set -euo pipefail

readonly VERSION="2.1.13"

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
# AI scan
AI_ENDPOINT=""          # OpenAI-compatible endpoint (e.g. http://localhost:11434/v1 for Ollama)
AI_API_KEY=""           # API key — empty for local models
AI_MODEL=""             # e.g. gpt-4o-mini, llama3, mistral

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
    return 0
  else
    log "$desc"
    if "$@" >> "$LOG_FILE" 2>&1; then
      return 0
    else
      warn "$desc failed (see $LOG_FILE)"
      return 1
    fi
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

# ── Config writer ─────────────────────────────────────────────────────────────
conf_set() {
  local key="$1" val="$2"
  # Always update the in-memory value so the current session sees it
  eval "${key}=${val}" 2>/dev/null || true
  if [[ ! -f "$CONF_FILE" ]]; then
    touch "$CONF_FILE" 2>/dev/null || { warn "Cannot write to ${CONF_FILE} — changes will not persist"; return 0; }
  fi
  if [[ ! -w "$CONF_FILE" ]]; then
    warn "Cannot write to ${CONF_FILE} — run as root to persist settings"
    return 0
  fi
  if grep -q "^${key}=" "$CONF_FILE" 2>/dev/null; then
    sed -i "s|^${key}=.*|${key}=${val}|" "$CONF_FILE" || true
  else
    echo "${key}=${val}" >> "$CONF_FILE" || true
  fi
}

# ── TUI ───────────────────────────────────────────────────────────────────────

tui_clear() { tput clear 2>/dev/null || printf '\033[2J\033[H'; }

tui_splash() {
  tui_clear
  echo ""
  echo -e "  ${GREEN} ▄▄▄▄ ▄▄    ▄▄▄▄▄  ▄▄▄  ▄▄  ▄▄ ▄▄ ▄▄ ▄▄ ▄▄${NC}"
  echo -e "  ${GREEN}██▀▀▀ ██    ██▄▄  ██▀██ ███▄██ ██ ██ ▀█▄█▀${NC}"
  echo -e "  ${GREEN}▀████ ██▄▄▄ ██▄▄▄ ██▀██ ██ ▀██ ▀███▀ ██ ██${NC}"
  echo ""
  echo -e "  ${DIM}v${VERSION} · server cleanup tool${NC}"
  echo ""
  sleep 1
}

tui_header() {
  local pct; pct=$(disk_used_pct)
  local free; free=$(disk_free_human)
  local color=$GREEN
  (( pct >= 90 )) && color=$RED || (( pct >= 75 )) && color=$YELLOW
  echo -e "  ${BOLD}cleanux${NC} v${VERSION}   ${DIM}disk: ${color}${pct}%${NC}${DIM} · ${free} free${NC}"
  [[ $EUID -ne 0 ]] && echo -e "  ${YELLOW}⚠${NC}  ${DIM}Not running as root — apt, journalctl and snap may fail${NC}"
  echo ""
}

tui_flash() {
  echo -e "\n  ${GREEN}✔${NC} $*"
  sleep 1
}

tui_read_key() {
  local key seq
  IFS= read -r -s -n1 key
  if [[ "$key" == $'\x1b' ]]; then
    IFS= read -r -s -n2 -t 0.1 seq || true
    key="${key}${seq}"
  fi
  printf '%s' "$key"
}

tui_modules() {
  local -a labels=(
    "Docker build cache"
    "Docker stopped containers"
    "Docker dangling images"
    "Docker unused volumes     (opt-in)"
    "Journal logs (${JOURNAL_KEEP_DAYS} days)"
    "APT / dnf / pacman cache"
    "APT autoremove            (opt-in)"
    "npm / yarn / pnpm cache"
    "pip cache"
    "Cargo registry cache      (opt-in)"
    "Go build cache            (opt-in)"
    "Snap old revisions"
    "Core dumps"
    "Temp files /tmp (${TMP_MAX_DAYS} days)"
    "Thumbnail cache           (opt-in)"
  )
  local -a state=(
    "$DOCKER_BUILDER" "$DOCKER_CONTAINERS" "$DOCKER_IMAGES" "$DOCKER_VOLUMES"
    "true" "$APT_CLEAN" "$APT_AUTOREMOVE" "$NPM_CACHE" "$PIP_CACHE"
    "$CARGO_CACHE" "$GO_CACHE" "$SNAP_REVISIONS" "$CORE_DUMPS"
    "true" "$THUMBNAIL_CACHE"
  )
  (( JOURNAL_KEEP_DAYS == 0 )) && state[4]=false
  (( TMP_MAX_DAYS == 0 ))      && state[13]=false

  local selected=0
  local n=${#labels[@]}

  while true; do
    tui_clear
    tui_header
    echo -e "  ${BOLD}Modules${NC}   ${DIM}Space toggle · s save · q back${NC}\n"
    for (( i=0; i<n; i++ )); do
      local mark; [[ "${state[$i]}" == true ]] && mark="${GREEN}✓${NC}" || mark=" "
      if (( i == selected )); then
        echo -e "  ${GREEN}❯${NC} [${mark}] ${BOLD}${labels[$i]}${NC}"
      else
        echo -e "    [${mark}] ${labels[$i]}"
      fi
    done
    echo -e "\n  ${DIM}↑↓ navigate   Space toggle   s save   q back${NC}"

    local key; key=$(tui_read_key)
    case "$key" in
      $'\x1b[A'|k) (( selected > 0 ))   && (( selected-- )) || true ;;
      $'\x1b[B'|j) (( selected < n-1 )) && (( selected++ )) || true ;;
      ' ')
        [[ "${state[$selected]}" == true ]] && state[$selected]=false || state[$selected]=true
        ;;
      s|S)
        DOCKER_BUILDER="${state[0]}"
        DOCKER_CONTAINERS="${state[1]}"
        DOCKER_IMAGES="${state[2]}"
        DOCKER_VOLUMES="${state[3]}"
        [[ "${state[4]}"  == false ]] && JOURNAL_KEEP_DAYS=0 || { (( JOURNAL_KEEP_DAYS == 0 )) && JOURNAL_KEEP_DAYS=14; }
        APT_CLEAN="${state[5]}"
        APT_AUTOREMOVE="${state[6]}"
        NPM_CACHE="${state[7]}"
        PIP_CACHE="${state[8]}"
        CARGO_CACHE="${state[9]}"
        GO_CACHE="${state[10]}"
        SNAP_REVISIONS="${state[11]}"
        CORE_DUMPS="${state[12]}"
        [[ "${state[13]}" == false ]] && TMP_MAX_DAYS=0  || { (( TMP_MAX_DAYS == 0 )) && TMP_MAX_DAYS=7; }
        THUMBNAIL_CACHE="${state[14]}"
        conf_set DOCKER_BUILDER    "$DOCKER_BUILDER"
        conf_set DOCKER_CONTAINERS "$DOCKER_CONTAINERS"
        conf_set DOCKER_IMAGES     "$DOCKER_IMAGES"
        conf_set DOCKER_VOLUMES    "$DOCKER_VOLUMES"
        conf_set JOURNAL_KEEP_DAYS "$JOURNAL_KEEP_DAYS"
        conf_set APT_CLEAN         "$APT_CLEAN"
        conf_set APT_AUTOREMOVE    "$APT_AUTOREMOVE"
        conf_set NPM_CACHE         "$NPM_CACHE"
        conf_set PIP_CACHE         "$PIP_CACHE"
        conf_set CARGO_CACHE       "$CARGO_CACHE"
        conf_set GO_CACHE          "$GO_CACHE"
        conf_set SNAP_REVISIONS    "$SNAP_REVISIONS"
        conf_set CORE_DUMPS        "$CORE_DUMPS"
        conf_set TMP_MAX_DAYS      "$TMP_MAX_DAYS"
        conf_set THUMBNAIL_CACHE   "$THUMBNAIL_CACHE"
        tui_flash "Saved to ${CONF_FILE}"
        return
        ;;
      q|Q|$'\x1b') return ;;
    esac
  done
}

tui_schedule() {
  local current
  current=$(grep -v '^#' /etc/cron.d/cleanux 2>/dev/null | awk '{print $1,$2,$3,$4,$5}' || echo "not set")
  systemctl is-enabled cleanux.timer &>/dev/null && current="systemd timer"

  local -a items=(
    "Weekly — Sunday at 03:00"
    "Daily  — 02:00"
    "Custom cron expression"
    "Use systemd timer"
    "Remove schedule"
    "Back"
  )
  local selected=0
  local n=${#items[@]}

  while true; do
    tui_clear
    tui_header
    echo -e "  ${BOLD}Schedule${NC}\n"
    echo -e "  Current: ${DIM}${current}${NC}\n"
    for (( i=0; i<n; i++ )); do
      if (( i == selected )); then
        echo -e "  ${GREEN}❯${NC} ${BOLD}${items[$i]}${NC}"
      else
        echo -e "    ${items[$i]}"
      fi
    done
    echo -e "\n  ${DIM}↑↓ navigate   Enter select   q back${NC}"

    local key; key=$(tui_read_key)
    case "$key" in
      $'\x1b[A'|k) (( selected > 0 ))   && (( selected-- )) || true ;;
      $'\x1b[B'|j) (( selected < n-1 )) && (( selected++ )) || true ;;
      ''|$'\n'|$'\r')
        case $selected in
          0) cmd_schedule "0 3 * * 0"; tui_flash "Scheduled: every Sunday at 03:00"; return ;;
          1) cmd_schedule "0 2 * * *"; tui_flash "Scheduled: every day at 02:00"; return ;;
          2)
            tui_clear; tui_header
            echo -e "  ${BOLD}Custom cron expression${NC}\n"
            echo -e "  ${DIM}minute hour day month weekday${NC}"
            echo -e "  ${DIM}e.g.  0 3 * * 0   (Sunday 03:00)${NC}\n"
            tput cnorm; printf "  > "; read -r expr; tput civis
            if [[ -n "$expr" ]]; then
              cmd_schedule "$expr"; tui_flash "Scheduled: ${expr}"; return
            fi
            ;;
          3) cmd_systemd; tui_flash "systemd timer installed"; return ;;
          4)
            rm -f /etc/cron.d/cleanux
            systemctl disable --now cleanux.timer 2>/dev/null || true
            tui_flash "Schedule removed"; return
            ;;
          5) return ;;
        esac
        ;;
      q|Q|$'\x1b') return ;;
    esac
  done
}

tui_notifications() {
  local selected=0
  local -a items=(
    "Set webhook URL  (Slack / Discord)"
    "Set email address"
    "Clear all notifications"
    "Back"
  )
  local n=${#items[@]}

  while true; do
    tui_clear
    tui_header
    echo -e "  ${BOLD}Notifications${NC}\n"
    [[ -n "$WEBHOOK_URL" ]]  && echo -e "  Webhook : ${DIM}${WEBHOOK_URL}${NC}" \
                             || echo -e "  Webhook : ${DIM}not set${NC}"
    [[ -n "$NOTIFY_EMAIL" ]] && echo -e "  Email   : ${DIM}${NOTIFY_EMAIL}${NC}\n" \
                             || echo -e "  Email   : ${DIM}not set${NC}\n"
    for (( i=0; i<n; i++ )); do
      if (( i == selected )); then
        echo -e "  ${GREEN}❯${NC} ${BOLD}${items[$i]}${NC}"
      else
        echo -e "    ${items[$i]}"
      fi
    done
    echo -e "\n  ${DIM}↑↓ navigate   Enter select   q back${NC}"

    local key; key=$(tui_read_key)
    case "$key" in
      $'\x1b[A'|k) (( selected > 0 ))   && (( selected-- )) || true ;;
      $'\x1b[B'|j) (( selected < n-1 )) && (( selected++ )) || true ;;
      ''|$'\n'|$'\r')
        tput cnorm
        case $selected in
          0)
            tui_clear; tui_header
            echo -e "  ${BOLD}Webhook URL${NC}  ${DIM}(Slack / Discord)${NC}\n"
            printf "  > "; read -r WEBHOOK_URL
            conf_set WEBHOOK_URL "\"${WEBHOOK_URL}\""
            tui_flash "Saved"
            ;;
          1)
            tui_clear; tui_header
            echo -e "  ${BOLD}Email address${NC}\n"
            printf "  > "; read -r NOTIFY_EMAIL
            conf_set NOTIFY_EMAIL "\"${NOTIFY_EMAIL}\""
            tui_flash "Saved"
            ;;
          2)
            WEBHOOK_URL=""; NOTIFY_EMAIL=""
            conf_set WEBHOOK_URL '""'; conf_set NOTIFY_EMAIL '""'
            tui_flash "Cleared"
            ;;
          3) tput civis; return ;;
        esac
        tput civis
        ;;
      q|Q|$'\x1b') return ;;
    esac
  done
}

tui_log() {
  tui_clear
  tui_header
  echo -e "  ${BOLD}Last log entries${NC}  ${DIM}${LOG_FILE}${NC}\n"
  if [[ -f "$LOG_FILE" ]]; then
    tail -30 "$LOG_FILE" | while IFS= read -r line; do echo "  $line"; done
  else
    echo -e "  ${DIM}No log file found.${NC}"
  fi
  echo -e "\n  ${DIM}Press any key to go back${NC}"
  tui_read_key > /dev/null
}

tui_run() {
  tput cnorm
  tui_clear
  FREED_TOTAL=0
  declare -gA MODULE_FREED=()
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
    local freed_human; freed_human=$(human_bytes "$FREED_TOTAL" 2>/dev/null || echo "0 B")
    notify "Cleanup complete — freed ${freed_human} — disk at $(disk_used_pct)%"
    log "=== cleanux done — freed ${freed_human} ==="
  fi
  echo -e "  ${DIM}Press any key to go back${NC}"
  read -r -s -n1
  tput civis
}

# ── Scan ──────────────────────────────────────────────────────────────────────

# Temp files used to store found paths per category
_SCAN_TMPDIR=""

scan_init() {
  _SCAN_TMPDIR=$(mktemp -d /tmp/cleanux_scan.XXXXXX)
}

scan_cleanup_tmp() {
  if [[ -n "$_SCAN_TMPDIR" && -d "$_SCAN_TMPDIR" ]]; then
    rm -rf "$_SCAN_TMPDIR"
  fi
  _SCAN_TMPDIR=""
}

# Each scan_* writes paths to a file and echoes "label|count|size_human"
_scan_size_of() {
  du -shc --files0-from=<(tr '\n' '\0' < "$1") 2>/dev/null | tail -1 | cut -f1 || echo '?'
}

scan_broken_symlinks() {
  local out="${_SCAN_TMPDIR}/broken_symlinks.txt"
  find /home /opt /usr/local -maxdepth 8 -xtype l 2>/dev/null > "$out" || true
  local count; count=$(wc -l < "$out")
  if (( count > 0 )); then
    echo "Broken symlinks|${count}|$(_scan_size_of "$out")|${out}"
  fi
}

scan_backup_files() {
  local out="${_SCAN_TMPDIR}/backup_files.txt"
  find /home -maxdepth 8 \
    \( -name "*.bak" -o -name "*.old" -o -name "*.orig" -o -name "*~" -o -name "*.swp" \) \
    -type f 2>/dev/null > "$out" || true
  local count; count=$(wc -l < "$out")
  if (( count > 0 )); then
    echo "Backup files (*.bak *.old *.orig *~ *.swp)|${count}|$(_scan_size_of "$out")|${out}"
  fi
}

scan_node_modules() {
  local out="${_SCAN_TMPDIR}/node_modules.txt"
  find /home /opt -name node_modules -type d -prune -atime +60 2>/dev/null > "$out" || true
  local count; count=$(wc -l < "$out")
  if (( count > 0 )); then
    local size; size=$(du -shc --files0-from=<(tr '\n' '\0' < "$out") 2>/dev/null | tail -1 | cut -f1 || echo '?')
    echo "node_modules not accessed in 60+ days|${count}|${size}|${out}"
  fi
}

scan_pycache() {
  local out="${_SCAN_TMPDIR}/pycache.txt"
  find /home -maxdepth 10 \
    \( -name "__pycache__" -type d -prune -o -name "*.pyc" -type f \) \
    2>/dev/null > "$out" || true
  local count; count=$(wc -l < "$out")
  if (( count > 0 )); then
    local size; size=$(du -shc --files0-from=<(tr '\n' '\0' < "$out") 2>/dev/null | tail -1 | cut -f1 || echo '?')
    echo "Python cache (__pycache__ and *.pyc)|${count}|${size}|${out}"
  fi
}

scan_large_old_files() {
  local out="${_SCAN_TMPDIR}/large_old.txt"
  find /home /opt /var/log -maxdepth 6 \
    -type f -size +100M -atime +30 \
    ! -path "*/proc/*" ! -path "*/sys/*" \
    2>/dev/null > "$out" || true
  local count; count=$(wc -l < "$out")
  if (( count > 0 )); then
    local size; size=$(du -shc --files0-from=<(tr '\n' '\0' < "$out") 2>/dev/null | tail -1 | cut -f1 || echo '?')
    echo "Files >100 MB not accessed in 30+ days|${count}|${size}|${out}"
  fi
}

scan_empty_dirs() {
  local out="${_SCAN_TMPDIR}/empty_dirs.txt"
  find /home -mindepth 1 -maxdepth 6 -type d -empty 2>/dev/null > "$out" || true
  local count; count=$(wc -l < "$out")
  if (( count > 0 )); then
    echo "Empty directories in /home|${count}|0B|${out}"
  fi
}

run_scan() {
  scan_init
  local line
  line=$(scan_broken_symlinks) || true; [[ -n "$line" ]] && echo "$line" || true
  line=$(scan_backup_files)    || true; [[ -n "$line" ]] && echo "$line" || true
  line=$(scan_node_modules)    || true; [[ -n "$line" ]] && echo "$line" || true
  line=$(scan_pycache)         || true; [[ -n "$line" ]] && echo "$line" || true
  line=$(scan_large_old_files) || true; [[ -n "$line" ]] && echo "$line" || true
  line=$(scan_empty_dirs)      || true; [[ -n "$line" ]] && echo "$line" || true
}

tui_scan_detail() {
  local label="$1" tmpfile="$2"
  local -a paths=()
  while IFS= read -r p; do
    [[ -n "$p" ]] && paths+=("$p")
  done < "$tmpfile"

  local total=${#paths[@]}
  local page_size=14
  local offset=0

  while true; do
    tui_clear
    tui_header
    echo -e "  ${BOLD}${label}${NC}   ${DIM}${total} items${NC}\n"

    local end=$(( offset + page_size ))
    (( end > total )) && end=$total

    for (( i=offset; i<end; i++ )); do
      local p="${paths[$i]}"
      local meta
      if [[ -d "$p" ]]; then
        meta=$(du -sh "$p" 2>/dev/null | cut -f1 || echo '?')
        echo -e "  ${DIM}$(printf '%4d' $(( i+1 )))${NC}  ${BLUE}[dir]${NC}  ${p}  ${DIM}${meta}${NC}"
      else
        meta=$(du -sh "$p" 2>/dev/null | cut -f1 || echo '?')
        echo -e "  ${DIM}$(printf '%4d' $(( i+1 )))${NC}  [file] ${p}  ${DIM}${meta}${NC}"
      fi
    done

    echo -e "\n  ${DIM}${end}/${total}   ↑↓ scroll   q back${NC}"

    local key; key=$(tui_read_key)
    case "$key" in
      $'\x1b[A'|k) (( offset > 0 )) && (( offset -= page_size )) || true; (( offset < 0 )) && offset=0 || true ;;
      $'\x1b[B'|j) (( offset + page_size < total )) && (( offset += page_size )) || true ;;
      q|Q|$'\x1b') return ;;
    esac
  done
}

# Delete all paths in a scan category's tmp file
scan_delete_category() {
  local label="$1"

  # Find the matching tmp file by searching all files
  local f
  for f in "${_SCAN_TMPDIR}"/*.txt; do
    [[ -f "$f" ]] || continue
    # Map label to filename heuristically
    local base; base=$(basename "$f" .txt)
    case "$label" in
      *symlink*)       [[ "$base" == "broken_symlinks" ]] || continue ;;
      *ackup*)         [[ "$base" == "backup_files" ]]    || continue ;;
      *node_modules*)  [[ "$base" == "node_modules" ]]    || continue ;;
      *ython*)         [[ "$base" == "pycache" ]]         || continue ;;
      *100*)           [[ "$base" == "large_old" ]]       || continue ;;
      *mpty*)          [[ "$base" == "empty_dirs" ]]      || continue ;;
      *) continue ;;
    esac
    while IFS= read -r path; do
      [[ -z "$path" ]] && continue
      if [[ -d "$path" ]]; then
        rm -rf "$path" 2>/dev/null && log "scan: removed dir $path" || warn "Failed to remove $path"
      else
        rm -f "$path" 2>/dev/null && log "scan: removed file $path" || warn "Failed to remove $path"
      fi
    done < "$f"
    return
  done
}

tui_scan() {
  tui_clear
  tui_header
  echo -e "  ${BOLD}Filesystem scan${NC}\n"
  echo -e "  ${DIM}Scanning — this may take a moment...${NC}"

  # Run scan and collect results
  local -a labels=()
  local -a counts=()
  local -a sizes=()
  local -a tmpfiles=()
  local -a selected=()

  while IFS='|' read -r label count size tmpfile; do
    labels+=("$label")
    counts+=("$count")
    sizes+=("$size")
    tmpfiles+=("$tmpfile")
    selected+=(false)
  done < <(run_scan)

  local n=${#labels[@]}

  if (( n == 0 )); then
    tui_clear
    tui_header
    echo -e "  ${BOLD}Filesystem scan${NC}\n"
    echo -e "  ${GREEN}✔${NC}  Nothing suspicious found.\n"
    echo -e "  ${DIM}Press any key to go back${NC}"
    tui_read_key > /dev/null
    scan_cleanup_tmp
    return
  fi

  local cursor=0

  while true; do
    tui_clear
    tui_header
    echo -e "  ${BOLD}Filesystem scan${NC}   ${DIM}Enter details · Space toggle · d delete · q back${NC}\n"

    for (( i=0; i<n; i++ )); do
      local mark; [[ "${selected[$i]}" == true ]] && mark="${RED}✓${NC}" || mark=" "
      if (( i == cursor )); then
        echo -e "  ${GREEN}❯${NC} [${mark}] ${BOLD}${labels[$i]}${NC}"
      else
        echo -e "    [${mark}] ${labels[$i]}"
      fi
      echo -e "         ${DIM}${counts[$i]} item(s) · ${sizes[$i]}${NC}"
    done

    # Count selected
    local sel_count=0
    for s in "${selected[@]}"; do [[ "$s" == true ]] && (( sel_count++ )) || true; done
    echo -e "\n  ${DIM}↑↓ navigate   Enter details   Space toggle   d delete (${sel_count} selected)   q back${NC}"

    local key; key=$(tui_read_key)
    case "$key" in
      $'\x1b[A'|k) (( cursor > 0 ))   && (( cursor-- )) || true ;;
      $'\x1b[B'|j) (( cursor < n-1 )) && (( cursor++ )) || true ;;
      ''|$'\n'|$'\r')
        tui_scan_detail "${labels[$cursor]}" "${tmpfiles[$cursor]}"
        ;;
      ' ')
        [[ "${selected[$cursor]}" == true ]] && selected[$cursor]=false || selected[$cursor]=true
        ;;
      d|D)
        (( sel_count == 0 )) && continue
        tui_clear
        tui_header
        echo -e "  ${BOLD}Confirm deletion${NC}\n"
        for (( i=0; i<n; i++ )); do
          [[ "${selected[$i]}" == true ]] && echo -e "  ${RED}✗${NC} ${labels[$i]}  ${DIM}(${counts[$i]} items · ${sizes[$i]})${NC}"
        done
        echo -e "\n  ${YELLOW}This cannot be undone.${NC}"
        echo -e "  ${DIM}Press Enter to confirm, q to cancel${NC}\n"
        local confirm; confirm=$(tui_read_key)
        if [[ "$confirm" == $'\n' || "$confirm" == $'\r' || "$confirm" == '' ]]; then
          log "=== scan deletion started ==="
          for (( i=0; i<n; i++ )); do
            [[ "${selected[$i]}" == true ]] || continue
            info "Removing: ${labels[$i]}..."
            scan_delete_category "${labels[$i]}"
            ok "Done"
          done
          log "=== scan deletion done ==="
          tui_flash "Deletion complete"
          scan_cleanup_tmp
          return
        fi
        ;;
      q|Q|$'\x1b')
        scan_cleanup_tmp
        return
        ;;
    esac
  done
}

tui_configure() {
  local -a items=("Modules" "Schedule" "Notifications" "AI" "Back")
  local cursor=0
  local n=${#items[@]}

  while true; do
    tui_clear
    tui_header
    echo -e "  ${BOLD}Configure${NC}\n"
    for (( i=0; i<n; i++ )); do
      if (( i == cursor )); then
        echo -e "  ${GREEN}❯${NC} ${BOLD}${items[$i]}${NC}"
      else
        echo -e "    ${items[$i]}"
      fi
    done
    echo -e "\n  ${DIM}↑↓ navigate   Enter select   q back${NC}"

    local key; key=$(tui_read_key)
    case "$key" in
      $'\x1b[A'|k) (( cursor > 0 ))   && (( cursor-- )) || true ;;
      $'\x1b[B'|j) (( cursor < n-1 )) && (( cursor++ )) || true ;;
      ''|$'\n'|$'\r')
        case $cursor in
          0) tui_modules ;;
          1) tui_schedule ;;
          2) tui_notifications ;;
          3) tui_ai_config ;;
          4) return ;;
        esac
        ;;
      q|Q|$'\x1b') return ;;
    esac
  done
}

tui_main() {
  tput civis
  trap 'tput cnorm; tput clear' EXIT INT TERM
  tui_splash

  local -a items=(
    "Run cleanup now"
    "Scan filesystem"
    "AI scan"
    "Configure"
    "View log"
    "Update cleanux"
    "Exit"
  )
  local idx=0
  local n=${#items[@]}

  while true; do
    tui_clear
    tui_header
    echo -e "  ${BOLD}Main menu${NC}\n"
    for (( i=0; i<n; i++ )); do
      if (( i == idx )); then
        echo -e "  ${GREEN}❯${NC} ${BOLD}${items[$i]}${NC}"
      else
        echo -e "    ${items[$i]}"
      fi
    done
    echo -e "\n  ${DIM}↑↓ navigate   Enter select   q quit${NC}"

    local key; key=$(tui_read_key)
    case "$key" in
      $'\x1b[A'|k) (( idx > 0 ))   && (( idx-- )) || true ;;
      $'\x1b[B'|j) (( idx < n-1 )) && (( idx++ )) || true ;;
      ''|$'\n'|$'\r')
        case $idx in
          0) tui_run ;;
          1) tui_scan ;;
          2) tui_ai_scan ;;
          3) tui_configure ;;
          4) tui_log ;;
          5)
            tput cnorm
            cmd_update || true
            echo -e "\n  ${DIM}Press any key to go back${NC}"
            read -r -s -n1
            tput civis
            ;;
          6) tput cnorm; tput clear; exit 0 ;;
        esac
        ;;
      q|Q) tput cnorm; tput clear; exit 0 ;;
    esac
  done
}

# ── AI scan ───────────────────────────────────────────────────────────────────

readonly AI_MODULE="/usr/local/lib/cleanux/ai.py"

_ai_module() {
  if [[ -f "$AI_MODULE" ]]; then
    echo "$AI_MODULE"
  elif [[ -f "$(dirname "$(command -v cleanux 2>/dev/null)")/cleanux-ai" ]]; then
    echo "$(dirname "$(command -v cleanux)")/cleanux-ai"
  else
    echo ""
  fi
}

_ai_run() {
  local mod; mod=$(_ai_module)
  if [[ -z "$mod" ]]; then
    echo '{"status":"error","message":"cleanux AI module not found — reinstall or run sudo cleanux --update"}'
    return 0
  fi
  CLEANUX_CONF="$CONF_FILE" python3 "$mod" 2>/dev/null || \
    echo '{"status":"error","message":"cleanux-ai exited with an error — check python3 is available"}'
}

# Parse a field from JSON output using python3
_ai_field() {
  local json="$1" field="$2"
  python3 -c "
import json, sys
try:
  d = json.loads(sys.argv[1])
  print(d.get('$field', ''))
except Exception:
  pass
" "$json" 2>/dev/null || true
}

_ai_rec_field() {
  local json="$1" idx="$2" field="$3"
  python3 -c "
import json, sys
try:
  d = json.loads(sys.argv[1])
  r = d.get('recommendations', [])[int(sys.argv[2])]
  print(r.get('$field', ''))
except Exception:
  pass
" "$json" "$idx" 2>/dev/null || true
}

_ai_rec_count() {
  local json="$1"
  python3 -c "
import json, sys
try:
  print(len(json.loads(sys.argv[1]).get('recommendations', [])))
except Exception:
  print(0)
" "$json" 2>/dev/null || echo 0
}

_human_bytes_py() {
  python3 -c "
b = int('$1' or 0)
if b >= 1073741824:   print(f'{b/1073741824:.1f} GB')
elif b >= 1048576:    print(f'{b/1048576:.1f} MB')
elif b > 0:           print(f'{b/1024:.0f} KB')
else:                 print('?')
" 2>/dev/null || echo '?'
}

_risk_color() {
  case "$1" in
    safe)   echo "$GREEN" ;;
    low)    echo "$GREEN" ;;
    medium) echo "$YELLOW" ;;
    high)   echo "$RED" ;;
    *)      echo "$NC" ;;
  esac
}

_ai_profile_list() {
  local mod; mod=$(_ai_module)
  [[ -z "$mod" ]] && echo "[]" && return
  python3 "$mod" --list-profiles 2>/dev/null || echo "[]"
}

_ai_profile_names() {
  local json="$1"
  python3 -c "
import json, sys
try:
  profiles = json.loads(sys.argv[1])
  for p in profiles:
    print(p.get('name',''))
except Exception:
  pass
" "$json" 2>/dev/null || true
}

_ai_profile_model() {
  local json="$1" name="$2"
  python3 -c "
import json, sys
try:
  for p in json.loads(sys.argv[1]):
    if p.get('name') == sys.argv[2]:
      print(p.get('model',''))
      break
except Exception:
  pass
" "$json" "$name" 2>/dev/null || true
}

_ai_profile_activate() {
  local name="$1"
  local mod; mod=$(_ai_module)
  [[ -z "$mod" ]] && warn "AI module not found" && return
  local result; result=$(python3 "$mod" --load-profile "$name" 2>/dev/null) || true
  local status; status=$(python3 -c "import json,sys; print(json.loads(sys.argv[1]).get('status',''))" "$result" 2>/dev/null) || true
  if [[ "$status" != "ok" ]]; then
    warn "Could not load profile '$name'"
    return
  fi
  AI_ENDPOINT=$(python3 -c "import json,sys; print(json.loads(sys.argv[1]).get('endpoint',''))" "$result" 2>/dev/null) || true
  AI_API_KEY=$(python3  -c "import json,sys; print(json.loads(sys.argv[1]).get('key',''))"      "$result" 2>/dev/null) || true
  AI_MODEL=$(python3    -c "import json,sys; print(json.loads(sys.argv[1]).get('model',''))"    "$result" 2>/dev/null) || true
  conf_set AI_ENDPOINT "\"${AI_ENDPOINT}\""
  conf_set AI_API_KEY  "\"${AI_API_KEY}\""
  conf_set AI_MODEL    "\"${AI_MODEL}\""
}

_ai_profile_add() {
  local mod; mod=$(_ai_module)
  tput cnorm
  echo ""
  echo -e "  ${BOLD}New profile${NC}\n"
  printf "  Name     > "; read -r p_name
  [[ -z "$p_name" ]] && tput civis && return
  echo -e "  ${DIM}OpenAI / Ollama: https://api.openai.com/v1  or  http://localhost:11434/v1${NC}"
  echo -e "  ${DIM}Azure OpenAI:   https://<resource>.openai.azure.com  (model = deployment name)${NC}"
  printf "  Endpoint > "; read -r p_endpoint
  printf "  API key  > "; read -r p_key
  printf "  Model    > "; read -r p_model
  if [[ -n "$mod" ]]; then
    python3 "$mod" --save-profile "$p_name" "$p_endpoint" "$p_key" "$p_model" > /dev/null 2>&1 || \
      warn "Could not save profile (run as root?)"
  fi
  # activate it immediately
  AI_ENDPOINT="$p_endpoint"; AI_API_KEY="$p_key"; AI_MODEL="$p_model"
  conf_set AI_ENDPOINT "\"${AI_ENDPOINT}\""
  conf_set AI_API_KEY  "\"${AI_API_KEY}\""
  conf_set AI_MODEL    "\"${AI_MODEL}\""
  tui_flash "Profile '${p_name}' saved and active"
  tput civis
}

tui_ai_config() {
  local cursor=0

  while true; do
    local profiles_json; profiles_json=$(_ai_profile_list)
    local -a prof_names=()
    while IFS= read -r name; do
      [[ -n "$name" ]] && prof_names+=("$name")
    done < <(_ai_profile_names "$profiles_json")
    local prof_count=${#prof_names[@]}
    # items: profiles + separator + "Add profile" + "Back"
    local total=$(( prof_count + 2 ))

    tui_clear
    tui_header
    echo -e "  ${BOLD}Configure AI${NC}\n"
    [[ -n "$AI_MODEL" ]] && echo -e "  Active: ${GREEN}${AI_MODEL}${NC}  ${DIM}${AI_ENDPOINT}${NC}\n" \
                         || echo -e "  ${DIM}No active profile${NC}\n"
    [[ $EUID -ne 0 ]] && echo -e "  ${YELLOW}⚠${NC}  ${DIM}Not root — profile activation applies to session only${NC}\n"

    # Draw profile list
    for (( i=0; i<prof_count; i++ )); do
      local model; model=$(_ai_profile_model "$profiles_json" "${prof_names[$i]}")
      local active_mark=""
      [[ "$AI_MODEL" == "$model" ]] && active_mark=" ${GREEN}●${NC}"
      if (( i == cursor )); then
        echo -e "  ${GREEN}❯${NC} ${BOLD}${prof_names[$i]}${NC}${active_mark}  ${DIM}${model}${NC}"
      else
        echo -e "    ${prof_names[$i]}${active_mark}  ${DIM}${model}${NC}"
      fi
    done

    # Separator + fixed items
    (( prof_count > 0 )) && echo -e "    ${DIM}──────────────────────${NC}"
    local add_idx=$prof_count
    local back_idx=$(( prof_count + 1 ))
    if (( cursor == add_idx )); then
      echo -e "  ${GREEN}❯${NC} ${BOLD}Add profile${NC}"
    else
      echo -e "    Add profile"
    fi
    if (( cursor == back_idx )); then
      echo -e "  ${GREEN}❯${NC} ${BOLD}Back${NC}"
    else
      echo -e "    Back"
    fi

    echo -e "\n  ${DIM}↑↓ navigate   Enter select   d delete profile   q back${NC}"

    local key; key=$(tui_read_key)
    case "$key" in
      $'\x1b[A'|k) (( cursor > 0 ))          && (( cursor-- )) || true ;;
      $'\x1b[B'|j) (( cursor < total-1 ))     && (( cursor++ )) || true ;;
      ''|$'\n'|$'\r')
        if (( cursor < prof_count )); then
          _ai_profile_activate "${prof_names[$cursor]}"
          tui_flash "Profile '${prof_names[$cursor]}' active"
        elif (( cursor == add_idx )); then
          _ai_profile_add
        else
          return
        fi
        ;;
      d|D)
        if (( cursor < prof_count )); then
          local mod; mod=$(_ai_module)
          [[ -n "$mod" ]] && python3 "$mod" --delete-profile "${prof_names[$cursor]}" > /dev/null 2>&1 || true
          tui_flash "Profile '${prof_names[$cursor]}' deleted"
          (( cursor > 0 )) && (( cursor-- )) || true
        fi
        ;;
      q|Q|$'\x1b') return ;;
    esac
  done
}

tui_ai_scan() {
  tui_clear
  tui_header
  echo -e "  ${BOLD}AI scan${NC}\n"

  if [[ -z "$AI_ENDPOINT" ]]; then
    echo -e "  ${YELLOW}⚠${NC}  No AI endpoint configured."
    echo -e "  Go to ${BOLD}Configure → AI${NC} to set one.\n"
    echo -e "  ${DIM}Press any key to go back${NC}"
    tui_read_key > /dev/null
    return
  fi

  echo -e "  ${DIM}AI is analyzing your system — this may take 20-60 seconds...${NC}"
  echo -e "  ${DIM}Model: ${AI_MODEL:-gpt-4o-mini} · ${AI_ENDPOINT}${NC}\n"

  local raw
  raw=$(_ai_run) || true

  local status; status=$(_ai_field "$raw" "status")

  if [[ "$status" != "ok" ]]; then
    local msg; msg=$(_ai_field "$raw" "message")
    tui_clear
    tui_header
    echo -e "  ${BOLD}AI scan${NC}\n"
    echo -e "  ${RED}✖${NC}  ${msg:-Unknown error}\n"
    echo -e "  ${DIM}Press any key to go back${NC}"
    tui_read_key > /dev/null
    return
  fi

  local summary;  summary=$(_ai_field  "$raw" "summary")
  local rec_count; rec_count=$(_ai_rec_count "$raw")

  if (( rec_count == 0 )); then
    tui_clear; tui_header
    echo -e "  ${BOLD}AI scan${NC}\n"
    echo -e "  ${GREEN}✔${NC}  ${summary}\n"
    echo -e "  No cleanup actions suggested.\n"
    echo -e "  ${DIM}Press any key to go back${NC}"
    tui_read_key > /dev/null
    return
  fi

  # Load recommendations into arrays
  local -a titles=() explanations=() commands=() risks=() sizes=()
  local -a selected=()
  local i
  for (( i=0; i<rec_count; i++ )); do
    titles+=("$(_ai_rec_field "$raw" "$i" "title")")
    explanations+=("$(_ai_rec_field "$raw" "$i" "explanation")")
    commands+=("$(_ai_rec_field "$raw" "$i" "command")")
    risks+=("$(_ai_rec_field "$raw" "$i" "risk")")
    local bytes; bytes=$(_ai_rec_field "$raw" "$i" "estimated_bytes")
    sizes+=("$(_human_bytes_py "$bytes")")
    selected+=(false)
  done

  local cursor=0

  while true; do
    tui_clear
    tui_header
    echo -e "  ${BOLD}AI scan${NC}   ${DIM}${AI_MODEL:-model}${NC}\n"
    echo -e "  ${DIM}${summary}${NC}\n"

    for (( i=0; i<rec_count; i++ )); do
      local mark; [[ "${selected[$i]}" == true ]] && mark="${GREEN}✓${NC}" || mark=" "
      local rc; rc=$(_risk_color "${risks[$i]}")
      if (( i == cursor )); then
        echo -e "  ${GREEN}❯${NC} [${mark}] ${BOLD}${titles[$i]}${NC}"
      else
        echo -e "    [${mark}] ${titles[$i]}"
      fi
      echo -e "         ${DIM}${sizes[$i]} · risk: ${rc}${risks[$i]}${NC}"
    done

    local sel_count=0
    for s in "${selected[@]}"; do [[ "$s" == true ]] && (( sel_count++ )) || true; done
    echo -e "\n  ${DIM}↑↓ navigate   Enter details   Space toggle   x execute (${sel_count} selected)   q back${NC}"

    local key; key=$(tui_read_key)
    case "$key" in
      $'\x1b[A'|k) (( cursor > 0 ))          && (( cursor-- )) || true ;;
      $'\x1b[B'|j) (( cursor < rec_count-1 )) && (( cursor++ )) || true ;;
      ' ') [[ "${selected[$cursor]}" == true ]] && selected[$cursor]=false || selected[$cursor]=true ;;
      ''|$'\n'|$'\r')
        # Detail view
        tui_clear; tui_header
        local rc; rc=$(_risk_color "${risks[$cursor]}")
        echo -e "  ${BOLD}${titles[$cursor]}${NC}"
        echo -e "  ${DIM}────────────────────────────────────────────────${NC}\n"
        echo -e "  ${DIM}Risk${NC}        ${rc}● ${risks[$cursor]}${NC}"
        echo -e "  ${DIM}Est. freed${NC}  ${sizes[$cursor]}\n"
        echo -e "  ${DIM}Why:${NC}"
        echo -e "  ${explanations[$cursor]}" | fold -s -w 72 | sed 's/^/  /'
        echo ""
        if [[ -n "${commands[$cursor]}" ]]; then
          echo -e "  ${DIM}Command:${NC}"
          echo -e "  ${BOLD}${commands[$cursor]}${NC}\n"
        fi
        local det_paths
        det_paths=$(python3 -c "
import json, sys
d = json.loads(sys.argv[1])
paths = d.get('recommendations', [])[${cursor}].get('paths', [])
print('\n'.join(paths[:10]))
" "$raw" 2>/dev/null) || true
        if [[ -n "$det_paths" ]]; then
          echo -e "  ${DIM}Paths:${NC}"
          while IFS= read -r p; do
            [[ -n "$p" ]] && echo -e "  ${DIM}  $p${NC}"
          done <<< "$det_paths"
          echo ""
        fi
        [[ "${selected[$cursor]}" == true ]] \
          && echo -e "  ${GREEN}✓ Selected for execution${NC}\n" \
          || echo -e "  ${DIM}Not selected${NC}\n"
        echo -e "  ${DIM}Space to toggle   q back${NC}"
        local dk; dk=$(tui_read_key)
        [[ "$dk" == ' ' ]] && { [[ "${selected[$cursor]}" == true ]] && selected[$cursor]=false || selected[$cursor]=true; }
        ;;
      x|X)
        (( sel_count == 0 )) && continue
        # Confirm screen
        tui_clear; tui_header
        echo -e "  ${BOLD}Confirm AI-recommended actions${NC}\n"
        for (( i=0; i<rec_count; i++ )); do
          [[ "${selected[$i]}" == false ]] && continue
          local rc; rc=$(_risk_color "${risks[$i]}")
          echo -e "  ${GREEN}✓${NC} ${titles[$i]}  ${DIM}${sizes[$i]} · ${rc}${risks[$i]}${NC}"
          [[ -n "${commands[$i]}" ]] && echo -e "    ${DIM}→ ${commands[$i]}${NC}"
        done
        echo -e "\n  ${YELLOW}This cannot be undone.${NC}"
        echo -e "  ${DIM}Press Enter to confirm, q to cancel${NC}\n"
        local ck; ck=$(tui_read_key)
        if [[ "$ck" == '' || "$ck" == $'\n' || "$ck" == $'\r' ]]; then
          tput cnorm
          echo ""
          log "=== AI scan execution started ==="
          for (( i=0; i<rec_count; i++ )); do
            [[ "${selected[$i]}" == false ]] && continue
            info "Running: ${titles[$i]}"
            if [[ -n "${commands[$i]}" ]]; then
              if eval "${commands[$i]}" >> "$LOG_FILE" 2>&1; then
                ok "${titles[$i]}"
              else
                warn "${titles[$i]} — command failed (see $LOG_FILE)"
              fi
            else
              # paths-only deletion
              local paths_json
              paths_json=$(python3 -c "
import json, sys
d = json.loads(sys.argv[1])
paths = d.get('recommendations', [])[${i}].get('paths', [])
print('\n'.join(paths))
" "$raw" 2>/dev/null) || true
              while IFS= read -r p; do
                [[ -z "$p" ]] && continue
                if [[ -d "$p" ]]; then
                  rm -rf "$p" && log "AI: removed dir $p" || warn "Failed: $p"
                else
                  rm -f  "$p" && log "AI: removed file $p" || warn "Failed: $p"
                fi
              done <<< "$paths_json"
              ok "${titles[$i]}"
            fi
          done
          log "=== AI scan execution done ==="
          tui_flash "Done"
          tput civis
          return
        fi
        ;;
      q|Q|$'\x1b') return ;;
    esac
  done
}

# ── Update ────────────────────────────────────────────────────────────────────

readonly REMOTE_URL="https://raw.githubusercontent.com/marcobarca/cleanux/main/cleanux.sh"

cmd_update() {
  local bin; bin=$(command -v cleanux 2>/dev/null || echo /usr/local/bin/cleanux)

  if ! has_cmd curl; then
    warn "curl is required for updates"
    return 0
  fi

  echo -e "\n${BOLD}cleanux update${NC}\n"
  info "Fetching latest version..."

  local tmp; tmp=$(mktemp)
  if ! curl -fsSL "$REMOTE_URL" -o "$tmp" 2>/dev/null; then
    warn "Could not reach GitHub. Check your connection."
    rm -f "$tmp"
    return 0
  fi

  local remote_version
  remote_version=$(grep '^readonly VERSION=' "$tmp" | cut -d'"' -f2)

  if [[ -z "$remote_version" ]]; then
    warn "Could not determine remote version."
    rm -f "$tmp"
    return 0
  fi

  if [[ "$remote_version" == "$VERSION" ]]; then
    ok "Already up to date (v${VERSION})"
    rm -f "$tmp"
    return 0
  fi

  echo -e "  ${DIM}Current : v${VERSION}${NC}"
  echo -e "  ${GREEN}Latest  : v${remote_version}${NC}\n"

  cp "$tmp" "$bin"
  chmod +x "$bin"
  rm -f "$tmp"

  # Update AI module
  local ai_mod="/usr/local/lib/cleanux/ai.py"
  local ai_url="https://raw.githubusercontent.com/marcobarca/cleanux/main/lib/cleanux_ai.py"
  if [[ -f "$ai_mod" ]] && has_cmd curl; then
    local tmp_ai; tmp_ai=$(mktemp)
    if curl -fsSL "$ai_url" -o "$tmp_ai" 2>/dev/null; then
      cp "$tmp_ai" "$ai_mod"
    fi
    rm -f "$tmp_ai"
  fi

  ok "Updated to v${remote_version}"
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
        if run_or_dry "apt-get clean" apt-get clean -qq; then
          [[ "$DRY_RUN" == false ]] && ok "APT cache cleared"
        fi
      fi
      if [[ "$APT_AUTOREMOVE" == true ]]; then
        info "Removing unused packages..."
        if run_or_dry "apt-get autoremove" apt-get autoremove -y -qq; then
          [[ "$DRY_RUN" == false ]] && ok "Unused packages removed"
        fi
      fi
      ;;
    dnf|yum)
      info "Cleaning $mgr cache..."
      if run_or_dry "$mgr clean" "$mgr" clean all -q; then
        [[ "$DRY_RUN" == false ]] && ok "$mgr cache cleared"
      fi
      ;;
    pacman)
      info "Cleaning pacman cache..."
      if has_cmd paccache; then run_or_dry "paccache" paccache -rk2
      else run_or_dry "pacman -Sc" pacman -Sc --noconfirm; fi
      [[ "$DRY_RUN" == false ]] && ok "Pacman cache cleared"
      ;;
    brew)
      info "Running brew cleanup..."
      if run_or_dry "brew cleanup" brew cleanup --prune=all; then
        if [[ "$DRY_RUN" == false ]]; then
          ok "Homebrew cache cleared"
          if has_cmd brew && [[ -f "Brewfile" ]]; then
            info "Removing formulae not in Brewfile..."
            run_or_dry "brew bundle cleanup" brew bundle cleanup --force && ok "Brewfile cleanup done" || true
          fi
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
      --update)                cmd_update; exit 0 ;;
      --ai-scan)
        # shellcheck source=/dev/null
        [[ -f "$CONF_FILE" ]] && source "$CONF_FILE"
        if [[ -z "$AI_ENDPOINT" ]]; then
          warn "AI_ENDPOINT not set. Configure it in ${CONF_FILE} or via the TUI."
          exit 1
        fi
        echo -e "\n${BOLD}AI scan${NC}\n"
        echo -e "${DIM}Collecting system info...${NC}"
        local ctx; ctx=$(ai_collect_context 2>/dev/null)
        echo -e "${DIM}Querying ${AI_MODEL:-model}...${NC}\n"
        ai_query "$ctx"
        echo ""
        exit 0 ;;
      --scan)
        # shellcheck source=/dev/null
        [[ -f "$CONF_FILE" ]] && source "$CONF_FILE"
        touch "$LOG_FILE" 2>/dev/null || LOG_FILE="/tmp/cleanux.log"
        echo -e "\n${BOLD}Filesystem scan${NC}\n"
        echo -e "${DIM}Scanning...${NC}\n"
        run_scan | while IFS='|' read -r label count size _tmpfile; do
          printf "  ${YELLOW}▸${NC} %-50s ${BOLD}%s${NC} items · %s\n" "$label" "$count" "$size"
        done
        echo ""
        scan_cleanup_tmp
        exit 0 ;;
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
  # No args + interactive terminal → launch TUI
  if [[ $# -eq 0 && -t 0 ]]; then
    # shellcheck source=/dev/null
    [[ -f "$CONF_FILE" ]] && source "$CONF_FILE"
    touch "$LOG_FILE" 2>/dev/null || LOG_FILE="/tmp/cleanux.log"
    rotate_log
    load_plugins
    tui_main
    exit 0
  fi

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

  [[ "$INTERACTIVE" == true ]] && tui_modules

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
