#!/usr/bin/env bash
# cleanux installer

set -euo pipefail

INSTALL_DIR="/usr/local/bin"
CONF_DIR="/etc"
SCRIPT_URL="https://raw.githubusercontent.com/YOUR_USERNAME/cleanux/main/cleanux.sh"
CONF_URL="https://raw.githubusercontent.com/YOUR_USERNAME/cleanux/main/cleanux.conf"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BOLD='\033[1m'; NC='\033[0m'

ok()   { echo -e "${GREEN}✔${NC} $*"; }
info() { echo -e "${BOLD}▸${NC} $*"; }
warn() { echo -e "${YELLOW}⚠${NC}  $*"; }
die()  { echo -e "${RED}✖${NC} $*"; exit 1; }

[[ $EUID -ne 0 ]] && die "Run as root: sudo bash install.sh"

# ── Install script ────────────────────────────────────────────────────────────
info "Installing cleanux..."

if [[ -f "cleanux.sh" ]]; then
  cp cleanux.sh "$INSTALL_DIR/cleanux"
else
  curl -fsSL "$SCRIPT_URL" -o "$INSTALL_DIR/cleanux"
fi

chmod +x "$INSTALL_DIR/cleanux"
ok "Installed to $INSTALL_DIR/cleanux"

# ── Install default config ────────────────────────────────────────────────────
if [[ ! -f "$CONF_DIR/cleanux.conf" ]]; then
  if [[ -f "cleanux.conf" ]]; then
    cp cleanux.conf "$CONF_DIR/cleanux.conf"
  else
    curl -fsSL "$CONF_URL" -o "$CONF_DIR/cleanux.conf"
  fi
  ok "Config written to $CONF_DIR/cleanux.conf"
else
  warn "Config already exists at $CONF_DIR/cleanux.conf — not overwritten"
fi

# ── Cron setup ────────────────────────────────────────────────────────────────
echo ""
read -r -p "Set up weekly cron job (every Sunday at 03:00)? [Y/n] " choice
choice="${choice:-Y}"

if [[ "$choice" =~ ^[Yy]$ ]]; then
  CRON_LINE="0 3 * * 0 root $INSTALL_DIR/cleanux -q"
  CRON_FILE="/etc/cron.d/cleanux"

  echo "$CRON_LINE" > "$CRON_FILE"
  chmod 644 "$CRON_FILE"
  ok "Cron job created at $CRON_FILE"
else
  info "Skipped. To add manually:"
  echo "    echo '0 3 * * 0 root /usr/local/bin/cleanux -q' > /etc/cron.d/cleanux"
fi

echo ""
ok "Done! Run ${BOLD}cleanux --dry-run${NC} to preview what will be cleaned."
