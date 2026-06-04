#!/usr/bin/env bash
# cleanux installer

set -euo pipefail

INSTALL_DIR="/usr/local/bin"
LIB_DIR="/usr/local/lib/cleanux"
CONF_DIR="/etc"
SCRIPT_URL="https://raw.githubusercontent.com/marcobarca/cleanux/main/cleanux.sh"
CONF_URL="https://raw.githubusercontent.com/marcobarca/cleanux/main/cleanux.conf"
AI_MODULE_URL="https://raw.githubusercontent.com/marcobarca/cleanux/main/lib/cleanux_ai.py"

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

# ── Install AI module ─────────────────────────────────────────────────────────
info "Installing AI module..."
mkdir -p "$LIB_DIR"
if [[ -f "lib/cleanux_ai.py" ]]; then
  cp lib/cleanux_ai.py "$LIB_DIR/ai.py"
else
  curl -fsSL "$AI_MODULE_URL" -o "$LIB_DIR/ai.py"
fi
ok "AI module installed to $LIB_DIR/ai.py"
mkdir -p /etc/cleanux/profiles
chmod 700 /etc/cleanux/profiles

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

echo ""
ok "Done! Run ${BOLD}cleanux${NC} to open the interactive menu."
