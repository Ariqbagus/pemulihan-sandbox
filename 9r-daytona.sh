#!/usr/bin/env bash
# ============================================================================
#  9r-daytona.sh — pasang & jalankan 9remote di Daytona sandbox
#  Adaptif: jalan dengan atau tanpa systemd, dengan atau tanpa sudo.
#
#  Pakai:
#    bash 9r-daytona.sh          # pasang + jalankan + cetak kode akses
#    bash 9r-daytona.sh --otk    # kode akses baru saja
#    bash 9r-daytona.sh --stop   # hentikan
# ============================================================================
set -uo pipefail

NODE_VER="v24.22.1"
MODE="${1:---all}"
API="http://127.0.0.1:2208"

ok()   { printf '\033[32m  ✓ %s\033[0m\n' "$*"; }
no()   { printf '\033[31m  ✗ %s\033[0m\n' "$*"; }
warn() { printf '\033[33m  ! %s\033[0m\n' "$*"; }
info() { printf '\033[36m  → %s\033[0m\n' "$*"; }
hdr()  { printf '\n\033[1m== %s ==\033[0m\n' "$*"; }

# --- deteksi lingkungan -----------------------------------------------------
if [ "$(id -u)" -eq 0 ]; then SUDO=""
elif sudo -n true 2>/dev/null; then SUDO="sudo -n"
else SUDO=""
fi
# Deteksi systemd: JANGAN pakai "systemctl is-system-running" — status "degraded"
# tetap berarti systemd ADA, tapi exit code-nya 1 dan membuat deteksi gagal.
HAS_SYSTEMD=0
if command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]; then HAS_SYSTEMD=1; fi

NODE_BIN="$(command -v node || true)"
NPM_BIN="$(command -v npm || true)"

# --- kode akses -------------------------------------------------------------
show_key() {
  hdr "Kode akses"
  local js otk tun i
  info "menunggu tunnel siap (bisa sampai ~120 detik)..."
  for i in $(seq 1 40); do
    js=$(curl -s -m 5 "${API}/api/ui/state" 2>/dev/null)
    otk=$(printf '%s' "$js" | python3 -c 'import sys,json;print(json.load(sys.stdin).get("oneTimeKey") or "")' 2>/dev/null)
    tun=$(printf '%s' "$js" | python3 -c 'import sys,json;print(json.load(sys.stdin).get("tunnelUrl") or "")' 2>/dev/null)
    [ -n "$otk" ] && [ -n "$tun" ] && break
    sleep 3
  done
  if [ -z "${otk:-}" ] || [ -z "${tun:-}" ]; then
    no "tunnel tidak siap. Cek: tail -50 ~/9remote.log"
    return 1
  fi
  ok "siap setelah ~$(( i * 3 )) detik"
  printf '\n  ┌────────────────────────────────────────────────────────┐\n'
  printf '  │ OTK    : %s\n' "$otk"
  printf '  │ tunnel : %s\n' "$tun"
  printf '  │ login  : %s\n' "$(printf '%s' "$js" | python3 -c 'import sys,json;print(json.load(sys.stdin).get("qrUrl") or "")' 2>/dev/null)"
  printf '  └────────────────────────────────────────────────────────┘\n\n'
  warn "OTK berlaku 30 menit / sekali pakai"
}

# --- stop -------------------------------------------------------------------
do_stop() {
  hdr "Hentikan"
  if [ "$HAS_SYSTEMD" = 1 ] && systemctl list-unit-files 2>/dev/null | grep -q '^9remote'; then
    $SUDO systemctl stop 9remote 2>/dev/null && ok "service dihentikan"
  fi
  pkill -f '/9remote start' 2>/dev/null
  pkill -f 'ptyDaemon.cjs' 2>/dev/null
  pkill -f 'cloudflared' 2>/dev/null
  sleep 1
  ok "selesai"
}

# --- pasang -----------------------------------------------------------------
do_install() {
  hdr "1/4 Node.js (butuh >= 22.5 untuk node:sqlite)"
  if [ -n "$NODE_BIN" ] && "$NODE_BIN" -e 'require("node:sqlite")' 2>/dev/null; then
    ok "sudah ada: $("$NODE_BIN" -v)"; return 0
  fi
  if [ -n "$SUDO" ] || [ "$(id -u)" -eq 0 ]; then DEST="/opt/node24"; else DEST="$HOME/.local/node24"; fi
  info "unduh ${NODE_VER} → ${DEST}"
  curl -fsSL "https://nodejs.org/dist/${NODE_VER}/node-${NODE_VER}-linux-x64.tar.xz" -o /tmp/n.tar.xz || { no "unduh gagal"; return 1; }
  $SUDO mkdir -p "$(dirname "$DEST")" || { no "tidak bisa buat $(dirname "$DEST")"; return 1; }
  $SUDO tar -xJf /tmp/n.tar.xz -C "$(dirname "$DEST")" || { no "extrak gagal"; return 1; }
  $SUDO rm -rf "$DEST"
  $SUDO mv "$(dirname "$DEST")/node-${NODE_VER}-linux-x64" "$DEST"
  $SUDO rm -f /tmp/n.tar.xz
  export PATH="$DEST/bin:$PATH"
  NODE_BIN="$DEST/bin/node"; NPM_BIN="$DEST/bin/npm"
  "$NODE_BIN" -e 'require("node:sqlite")' 2>/dev/null && ok "node $("$NODE_BIN" -v) siap" || { no "node:sqlite gagal"; return 1; }
}

do_pkg() {
  hdr "2/4 Paket 9remote"
  if command -v 9remote >/dev/null 2>&1; then ok "sudah terpasang"; return 0; fi
  [ -n "$NPM_BIN" ] || NPM_BIN="$(command -v npm || true)"
  [ -n "$NPM_BIN" ] || { no "npm tidak ditemukan"; return 1; }
  info "npm install -g 9remote (259 paket, 1-2 menit)"
  $SUDO "$NPM_BIN" install -g 9remote 2>&1 | tail -3
  command -v 9remote >/dev/null 2>&1 && ok "terpasang" || { no "gagal, cek error di atas"; return 1; }
}

do_run() {
  hdr "3/4 Jalankan"
  if curl -s -o /dev/null -m 2 "${API}/api/health" 2>/dev/null; then ok "sudah jalan"; return 0; fi
  local RBIN; RBIN="$(command -v 9remote)"
  if [ "$HAS_SYSTEMD" = 1 ]; then
    info "systemd terdeteksi → pakai unit service"
    $SUDO tee /etc/systemd/system/9remote.service >/dev/null <<EOF
[Unit]
Description=9Remote Host
After=network-online.target

[Service]
Type=simple
ExecStart=${NODE_BIN} ${RBIN} start
Restart=always
RestartSec=5
Environment=HOME=$HOME
Environment=PATH=$(dirname "$NODE_BIN"):/usr/local/bin:/usr/bin:/bin
WorkingDirectory=$HOME
StandardOutput=append:$HOME/9remote.log
StandardError=append:$HOME/9remote.log

[Install]
WantedBy=multi-user.target
EOF
    $SUDO systemctl daemon-reload
    $SUDO systemctl enable --now 9remote
  else
    warn "TANPA systemd → jalankan latar dengan nohup + watchdog"
    cat > "$HOME/9r-keepalive.sh" <<'KL'
#!/bin/bash
while true; do
  if ! curl -s -o /dev/null -m 2 http://127.0.0.1:2208/api/health; then
    pkill -f '/9remote start' 2>/dev/null; pkill -f cloudflared 2>/dev/null
    sleep 2
    nohup "$(command -v 9remote)" start >> "$HOME/9remote.log" 2>&1 &
  fi
  sleep 30
done
KL
    chmod +x "$HOME/9r-keepalive.sh"
    nohup "$RBIN" start >> "$HOME/9remote.log" 2>&1 &
    nohup "$HOME/9r-keepalive.sh" >> "$HOME/9r-keepalive.log" 2>&1 &
    ok "dijalankan (watchdog tiap 30 detik)"
  fi
  local i
  for i in $(seq 1 30); do
    curl -s -o /dev/null -m 2 "${API}/api/health" 2>/dev/null && { ok "API :2208 hidup"; return 0; }
    sleep 1
  done
  no "API tidak hidup — cek: tail -50 ~/9remote.log"; return 1
}

do_access() {
  hdr "4/4 Akses"
  curl -s -X POST "${API}/api/device/auto-approve" -H 'Content-Type: application/json' \
    -d '{"enabled":true}' >/dev/null 2>&1 && ok "auto-approve: ON" || warn "auto-approve gagal"
  show_key
}

case "$MODE" in
  --otk)  show_key ;;
  --stop) do_stop ;;
  --all)
    hdr "9r-daytona — $(whoami)@$(hostname) | systemd=$HAS_SYSTEMD"
    do_install && do_pkg && do_run && do_access
    ;;
  *) echo "pakai: bash $0 [--all|--otk|--stop]" ;;
esac
