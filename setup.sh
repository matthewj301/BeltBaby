#!/usr/bin/env bash
#
# BabyBelt Pro V2.5 — Kalico Host Setup Script
#
# Installs and configures:
#   1. System prerequisites & host tuning
#   2. KIAUH (Klipper Installation And Update Helper)
#   3. Kalico (Klipper fork) via KIAUH custom repo
#   4. Katapult (CAN/USB/UART bootloader)
#   5. TMC Autotune (stepper driver auto-tuning)
#
# Usage:
#   chmod +x setup.sh && ./setup.sh
#
# Intended for a fresh Raspberry Pi OS Lite (or similar Debian-based SBC).
# Must be run as a normal user (not root) — the script uses sudo where needed.
#

set -euo pipefail

# ── Colors & helpers ──────────────────────────────────────────────────────────

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

info()    { echo -e "${CYAN}[INFO]${NC} $*"; }
success() { echo -e "${GREEN}[OK]${NC}   $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $*"; }
error()   { echo -e "${RED}[ERR]${NC}  $*"; exit 1; }

section() {
    echo ""
    echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${BOLD}  $*${NC}"
    echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
}

# ── Preflight checks ─────────────────────────────────────────────────────────

if [[ $EUID -eq 0 ]]; then
    error "Do not run this script as root. Run as your normal user — sudo is used where needed."
fi

if ! command -v apt-get &>/dev/null; then
    error "This script requires a Debian-based system (apt-get not found)."
fi

# ── 1. System Prerequisites ──────────────────────────────────────────────────

section "1/5  System Prerequisites"

info "Updating package lists..."
sudo apt-get update -qq

info "Installing base dependencies..."
sudo apt-get install -y \
    git \
    wget \
    curl \
    build-essential \
    python3 \
    python3-pip \
    python3-venv \
    python3-dev \
    libffi-dev \
    libncurses-dev \
    avrdude \
    gcc-arm-none-eabi \
    binutils-arm-none-eabi \
    libnewlib-arm-none-eabi \
    stm32flash \
    dfu-util \
    can-utils \
    usbutils \
    unzip \
    2>&1 | tail -1

success "System dependencies installed."

# ── 2. Host Tuning for Klipper / Kalico ──────────────────────────────────────

section "2/5  Host Tuning"

# 2a. CPU governor → performance (reduces jitter for stepper timing)
if [[ -d /sys/devices/system/cpu/cpufreq ]]; then
    info "Setting CPU governor to 'performance'..."
    sudo apt-get install -y cpufrequtils -qq 2>/dev/null || true
    echo 'GOVERNOR="performance"' | sudo tee /etc/default/cpufrequtils > /dev/null
    sudo systemctl restart cpufrequtils 2>/dev/null || true
    success "CPU governor set to performance."
else
    warn "cpufreq not available — skipping governor tuning."
fi

# 2b. USB latency timer (reduces latency for USB serial MCU connections)
USB_LATENCY_RULE="/etc/udev/rules.d/99-klipper-usb-latency.rules"
if [[ ! -f "$USB_LATENCY_RULE" ]]; then
    info "Adding udev rule to reduce USB serial latency..."
    echo 'SUBSYSTEM=="tty", ATTRS{idVendor}=="1d50", ATTRS{idProduct}=="614e", ATTR{../latency_timer}="1"' \
        | sudo tee "$USB_LATENCY_RULE" > /dev/null
    sudo udevadm control --reload-rules
    success "USB latency udev rule installed."
else
    success "USB latency udev rule already exists."
fi

# 2c. CAN interface setup (creates a default can0 config if not present)
CAN_IFACE_FILE="/etc/network/interfaces.d/can0"
if [[ ! -f "$CAN_IFACE_FILE" ]]; then
    info "Creating default CAN interface (can0) config..."
    sudo tee "$CAN_IFACE_FILE" > /dev/null <<'CANEOF'
allow-hotplug can0
iface can0 can static
    bitrate 1000000
    up ip link set $IFACE txqueuelen 1024
CANEOF
    success "CAN interface config created (1Mbit, txqueuelen 1024)."
    warn "Adjust bitrate in $CAN_IFACE_FILE if your setup uses a different speed."
else
    success "CAN interface config already exists."
fi

# 2d. Increase kernel real-time scheduling priority allowance
RT_CONF="/etc/security/limits.d/99-klipper-rt.conf"
if [[ ! -f "$RT_CONF" ]]; then
    info "Allowing real-time scheduling priority for current user..."
    echo "${USER} - nice -20" | sudo tee "$RT_CONF" > /dev/null
    echo "${USER} - rtprio 99" | sudo tee -a "$RT_CONF" > /dev/null
    success "RT scheduling limits configured."
else
    success "RT scheduling limits already configured."
fi

# ── 3. KIAUH + Kalico ────────────────────────────────────────────────────────

section "3/5  KIAUH + Kalico"

KIAUH_DIR="$HOME/kiauh"

if [[ -d "$KIAUH_DIR" ]]; then
    info "KIAUH already cloned — pulling latest..."
    git -C "$KIAUH_DIR" pull --ff-only
else
    info "Cloning KIAUH..."
    git clone https://github.com/dw-0/kiauh.git "$KIAUH_DIR"
fi
success "KIAUH ready at $KIAUH_DIR"

# Configure KIAUH to use Kalico instead of stock Klipper
KIAUH_CFG="$KIAUH_DIR/kiauh.cfg"
if [[ ! -f "$KIAUH_CFG" ]]; then
    info "Creating KIAUH custom config for Kalico..."
    if [[ -f "$KIAUH_DIR/default.kiauh.cfg" ]]; then
        cp "$KIAUH_DIR/default.kiauh.cfg" "$KIAUH_CFG"
    else
        # Fallback: create minimal config
        cat > "$KIAUH_CFG" <<'KIAUEOF'
# KIAUH Custom Configuration
[klipper]
repo_url=https://github.com/KalicoCrew/kalico
branch=main
KIAUEOF
    fi
fi

# Ensure the Kalico repo is set in the config
if ! grep -q "KalicoCrew/kalico" "$KIAUH_CFG" 2>/dev/null; then
    info "Pointing KIAUH klipper source to Kalico..."
    # Try sed replacement first; if the key exists, update it
    if grep -q "^repo_url=" "$KIAUH_CFG" 2>/dev/null; then
        sed -i 's|^repo_url=.*|repo_url=https://github.com/KalicoCrew/kalico|' "$KIAUH_CFG"
        sed -i 's|^branch=.*|branch=main|' "$KIAUH_CFG"
    else
        cat >> "$KIAUH_CFG" <<'KIAUEOF'

[klipper]
repo_url=https://github.com/KalicoCrew/kalico
branch=main
KIAUEOF
    fi
fi
success "KIAUH configured to install Kalico (KalicoCrew/kalico, main branch)."

# ── 4. Katapult ──────────────────────────────────────────────────────────────

section "4/5  Katapult (CAN/USB/UART Bootloader)"

KATAPULT_DIR="$HOME/katapult"

if [[ -d "$KATAPULT_DIR" ]]; then
    info "Katapult already cloned — pulling latest..."
    git -C "$KATAPULT_DIR" pull --ff-only
else
    info "Cloning Katapult..."
    git clone https://github.com/Arksine/katapult.git "$KATAPULT_DIR"
fi
success "Katapult ready at $KATAPULT_DIR"
info "To build Katapult for your MCU:"
echo "    cd $KATAPULT_DIR"
echo "    make menuconfig   # select your MCU, interface, and offsets"
echo "    make"

# ── 5. TMC Autotune ─────────────────────────────────────────────────────────

section "5/5  TMC Autotune"

TMC_AUTOTUNE_DIR="$HOME/klipper_tmc_autotune"

if [[ -d "$TMC_AUTOTUNE_DIR" ]]; then
    info "TMC Autotune already cloned — pulling latest..."
    git -C "$TMC_AUTOTUNE_DIR" pull --ff-only
else
    info "Cloning TMC Autotune..."
    git clone https://github.com/andrewmcgr/klipper_tmc_autotune.git "$TMC_AUTOTUNE_DIR"
fi

# Symlink the autotune extra into Klipper's extras directory
KLIPPER_EXTRAS="$HOME/klipper/klippy/extras"
if [[ -d "$KLIPPER_EXTRAS" ]]; then
    for f in "$TMC_AUTOTUNE_DIR"/autotune_tmc*.py "$TMC_AUTOTUNE_DIR"/tmc_autotune*.py; do
        [[ -f "$f" ]] || continue
        BASENAME=$(basename "$f")
        if [[ ! -L "$KLIPPER_EXTRAS/$BASENAME" ]]; then
            ln -sf "$f" "$KLIPPER_EXTRAS/$BASENAME"
            success "Linked $BASENAME → klipper/klippy/extras/"
        fi
    done
else
    warn "Klipper extras directory not found yet."
    info "TMC Autotune will be linked after you install Kalico via KIAUH."
    info "Re-run this script or manually link:"
    echo "    ln -sf $TMC_AUTOTUNE_DIR/autotune_tmc*.py ~/klipper/klippy/extras/"
fi
success "TMC Autotune ready at $TMC_AUTOTUNE_DIR"

# ── Summary ──────────────────────────────────────────────────────────────────

section "Setup Complete"

cat <<'SUMMARY'
  All components are installed and configured. Next steps:

  1. LAUNCH KIAUH to install Kalico, Moonraker, and your web UI:

         cd ~/kiauh && ./kiauh.sh

     In KIAUH:
       → Install Klipper     (will use Kalico automatically)
       → Install Moonraker
       → Install Mainsail or Fluidd (your preference)
       → Install KlipperScreen (optional, if you have a display)

  2. BUILD & FLASH Katapult bootloader for your MCU(s):

         cd ~/katapult && make menuconfig && make

  3. BUILD & FLASH Kalico firmware for your MCU(s):

         cd ~/klipper && make menuconfig && make

  4. CONFIGURE your printer:
     - Copy/create your printer.cfg in ~/printer_data/config/
     - Add TMC Autotune sections, e.g.:

         [autotune_tmc stepper_x]
         motor: ldo-42sth48-2004mah
         tuning_goal: auto

     - Adjust CAN bitrate in /etc/network/interfaces.d/can0 if needed

  5. REBOOT to apply host tuning (CPU governor, RT limits):

         sudo reboot

SUMMARY

echo -e "${GREEN}${BOLD}  Happy printing with your BabyBelt Pro V2.5!${NC}"
echo ""
