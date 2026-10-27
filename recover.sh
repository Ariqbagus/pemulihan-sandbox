#!/usr/bin/env bash
# ============================================================================
#  recover.sh — pemulihan satu perintah untuk sandbox E2B / workspace Arena
#
#  Kenapa file ini ada:
#    Sandbox ini lahir ulang tanpa pemberitahuan. Saat itu terjadi:
#      - /home/user dipulihkan dari snapshot (perubahan terakhir bisa hilang)
#      - semua paket apt/global-npm hilang
#      - /etc/systemd/system hilang
#      - semua proses mati, tunnel + OTK hangus
#    Yang SELAMAT cuma /home/user (minus folder yang dikecualikan).
#
#  Jadi: simpan file ini DI LUAR sandbox (GitHub / HP / Drive).
#        Setelah sandbox lahir ulang, taruh lagi di ~/ lalu jalankan.
#
#  Pemakaian:
#    bash recover.sh              # pulihkan semua (install + service + kode akses)
#    bash recover.sh --status     # lihat keadaan sekarang, tanpa mengubah apa pun
#    bash recover.sh --doctor     # diagnosis kalau ada yang tidak jalan
#    bash recover.sh --otk        # minta kode akses baru saja
#    bash recover.sh --clean      # hapus semua yang dipasang skrip ini
#    bash recover.sh --dry-run    # tunjukkan rencana, tanpa eksekusi
# ============================================================================
set -uo pipefail

# ---- Konstanta -------------------------------------------------------------
NODE_VER="v24.22.1"
NODE_TAR="node-${NODE_VER}-linux-x64.tar.xz"
NODE_URL="https://nodejs.org/dist/${NODE_VER}/${NODE_TAR}"
# PENTING: Node ditaruh DI LUAR /home/user.
#   Di dalam ~/ ia akan ikut ter-zip ke snapshot (200 MB > kuota 128 MB)
#   dan bisa membuat snapshot gagal / file di-omit. Di luar ~/ ia memang
#   hilang saat restart — tapi skrip ini mengunduhnya ulang dalam ~15 detik.
RUNTIME="/opt/9remote-node"
NODE_BIN="${RUNTIME}/node24/bin/node"
NPM_BIN="${RUNTIME}/node24/bin/npm"
UNIT="/etc/systemd/system/9remote.service"
PORT=2208
API="http://127.0.0.1:${PORT}"
MODE="${1:---all}"
DRY=0
[ "$MODE" = "--dry-run" ] && DRY=1

# ---- Util ------------------------------------------------------------------
c_ok()   { printf '\033[32m  ✓ %s\033[0m\n' "$*"; }
c_no()   { printf '\033[31m  ✗ %s\033[0m\n' "$*"; }
c_warn() { printf '\033[33m  ! %s\033[0m\n' "$*"; }
c_info() { printf '\033[36m  → %s\033[0m\n' "$*"; }
hdr()    { printf '\n\033[1m== %s ==\033[0m\n' "$*"; }
run()    { if [ "$DRY" = 1 ]; then printf '    [dry-run] %s\n' "$*"; else eval "$@"; fi; }

api_up() { curl -s -o /dev/null -m 2 -w '%{http_code}' "${API}/api/health" 2>/dev/null | grep -q 200; }

wait_api() {
  local i
  for i in $(seq 1 30); do api_up && return 0; sleep 1; done
  return 1
}

# ---- Mode: --status --------------------------------------------------------
do_status() {
  hdr "Status"
  printf '  sandbox id   : %s\n' "${E2B_SANDBOX_ID:-<tidak ada env>}"
  printf '  template id  : %s\n' "${E2B_TEMPLATE_ID:-<tidak ada env>}"
  printf '  uptime       : %s\n' "$(uptime -p 2>/dev/null | sed 's/^up //')"
  printf '  disk         : %s\n' "$(df -h / | awk 'NR==2{print $3" / "$2" ("$5")"}')"
  printf '  RAM          : %s\n' "$(free -m | awk 'NR==2{print $3" MB / "$2" MB"}')"
  echo
  [ -x "$NODE_BIN" ] && c_ok "node      : $("$NODE_BIN" -v 2>/dev/null)" || c_no "node      : belum ada di $NODE_BIN"
  [ -x /usr/bin/9remote ] && c_ok "9remote   : terpasang" || c_no "9remote   : belum terpasang"
  systemctl is-enabled 9remote >/dev/null 2>&1 && c_ok "service   : enabled" || c_no "service   : tidak enabled"
  systemctl is-active  9remote >/dev/null 2>&1 && c_ok "proses    : running" || c_no "proses    : mati"
  api_up && c_ok "API :$PORT  : jawab 200" || c_no "API :$PORT  : tidak menjawab"
  echo
  local sz
  sz=$(du -sm "$HOME" 2>/dev/null | awk '{print $1}')
  if [ -n "${sz:-}" ]; then
    if [ "$sz" -lt 100 ]; then c_ok "ukuran ~   : ${sz} MB dari kuota ~128 MB"
    else c_warn "ukuran ~   : ${sz} MB — MENDEKATI/MELEWATI kuota 128 MB"; fi
  fi
  echo
  c_info "isi /home/user (yang IKUT tersimpan):"
  find "$HOME" -mindepth 1 -maxdepth 1 -printf '      %f\n' 2>/dev/null | sort
}

# ---- Langkah 1: Node -------------------------------------------------------
step_node() {
  hdr "1/4 Node.js"
  if [ -x "$NODE_BIN" ] && "$NODE_BIN" -e 'require("node:sqlite")' 2>/dev/null; then
    c_ok "sudah ada: $("$NODE_BIN" -v) (node:sqlite OK) — dilewati"
    return 0
  fi
  c_info "unduh ${NODE_VER} → ${RUNTIME}/node24 (di luar ~, hemat kuota snapshot)"
  run "sudo -n mkdir -p '$RUNTIME'"
  run "curl -sSL -o /tmp/${NODE_TAR} '$NODE_URL'"
  run "sudo -n tar -xJf /tmp/${NODE_TAR} -C '$RUNTIME'"
  run "sudo -n rm -rf '${RUNTIME}/node24'"
  run "sudo -n mv '${RUNTIME}/node-${NODE_VER}-linux-x64' '${RUNTIME}/node24'"
  run "rm -f /tmp/${NODE_TAR}"
  if [ "$DRY" = 0 ]; then
    "$NODE_BIN" -e 'require("node:sqlite")' 2>/dev/null \
      && c_ok "node siap: $("$NODE_BIN" -v)" \
      || { c_no "node gagal: node:sqlite tidak tersedia"; return 1; }
  fi
}

# ---- Langkah 2: paket 9remote ---------------------------------------------
step_install() {
  hdr "2/4 Paket 9remote"
  if [ -x /usr/bin/9remote ]; then c_ok "sudah terpasang — dilewati"; return 0; fi
  c_info "npm install -g 9remote (paket global TIDAK ikut snapshot)"
  run "sudo -n '$NPM_BIN' install -g 9remote"
  if [ "$DRY" = 0 ]; then
    [ -x /usr/bin/9remote ] && c_ok "terpasang" || { c_no "gagal terpasang"; return 1; }
  fi
}

# ---- Langkah 3: systemd ----------------------------------------------------
step_service() {
  hdr "3/4 Service (tahan crash, TIDAK tahan restart sandbox)"
  c_warn "unit ini hilang tiap sandbox lahir ulang — jalankan ulang skrip ini setelahnya"
  run "sudo -n tee '$UNIT' >/dev/null <<'UNITEOF'
[Unit]
Description=9Remote Host
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=${NODE_BIN} /usr/bin/9remote start
Restart=always
RestartSec=5
Environment=HOME=${HOME}
WorkingDirectory=${HOME}
StandardOutput=append:${HOME}/9remote.log
StandardError=append:${HOME}/9remote.log

[Install]
WantedBy=multi-user.target
UNITEOF"
  run "sudo -n systemctl daemon-reload"
  run "sudo -n systemctl enable --now 9remote"
  if [ "$DRY" = 0 ]; then
    wait_api && c_ok "API :$PORT hidup" || { c_no "API tidak hidup — cek: bash recover.sh --doctor"; return 1; }
  fi
}

# ---- Langkah 4: akses ------------------------------------------------------
step_access() {
  hdr "4/4 Akses dari HP"
  if [ "$DRY" = 1 ]; then printf '    [dry-run] POST auto-approve + baca /api/ui/state\n'; return 0; fi
  curl -s -X POST "${API}/api/device/auto-approve" \
       -H 'Content-Type: application/json' -d '{"enabled":true}' >/dev/null 2>&1 \
    && c_ok "auto-approve: ON" || c_warn "auto-approve gagal di-set"

  local js
  js=$(curl -s -m 5 "${API}/api/ui/state" 2>/dev/null)
  if [ -z "$js" ]; then c_no "tidak bisa baca /api/ui/state"; return 1; fi

  c_info "kode akses — SATU-SATUNYA sumber yang sah (jangan pakai '9remote otk'):"
  printf '\n  ┌─────────────────────────────────────────────────────────┐\n'
  printf '  │  %s\n' "$(printf '%s' "$js" | python3 -c 'import sys,json;d=json.load(sys.stdin);print("OTK   :",d.get("oneTimeKey","?"))' 2>/dev/null)"
  printf '  │  %s\n' "$(printf '%s' "$js" | python3 -c 'import sys,json;d=json.load(sys.stdin);print("tunnel:",d.get("tunnelUrl","?"))' 2>/dev/null)"
  printf '  │  %s\n' "$(printf '%s' "$js" | python3 -c 'import sys,json;d=json.load(sys.stdin);print("login :",d.get("qrUrl","?"))' 2>/dev/null)"
  printf '  └─────────────────────────────────────────────────────────┘\n\n'
  c_warn "OTK cuma hidup 30 menit / sekali pakai. Mati saat sandbox lahir ulang."
}

# ---- Mode: --doctor --------------------------------------------------------
do_doctor() {
  hdr "Doctor"
  local bad=0
  chk() { if eval "$2" >/dev/null 2>&1; then c_ok "$1"; else c_no "$1"; bad=$((bad+1)); fi; }

  chk "node biner ada"                 "[ -x '$NODE_BIN' ]"
  chk "node >= 22.5 (butuh node:sqlite)" "[ -x '$NODE_BIN' ] && '$NODE_BIN' -e 'require(\"node:sqlite\")'"
  chk "9remote terpasang"              "[ -x /usr/bin/9remote ]"
  chk "unit systemd ada"               "[ -f '$UNIT' ]"
  chk "port $PORT mendengarkan"        "ss -ltn | grep -q ':${PORT}'"
  chk "API jawab 200"                  "api_up"
  chk "sudo tanpa password"            "sudo -n true"
  echo
  if api_up; then
    c_info "worker vs host sinkron? (kalau beda → kode akses akan ditolak)"
    local host_t w_t
    host_t=$(curl -s -m 3 "${API}/api/ui/state" | python3 -c 'import sys,json;print(json.load(sys.stdin).get("tunnelUrl",""))' 2>/dev/null)
    w_t=$(sudo -n cat "${HOME}/.9remote/state/state.json" 2>/dev/null | python3 -c 'import sys,json;print(json.load(sys.stdin).get("tunnelUrl",""))' 2>/dev/null)
    printf '      ui-state   : %s\n      state.json : %s\n' "$host_t" "$w_t"
    [ "$host_t" = "$w_t" ] && c_ok "sinkron" || c_warn "TIDAK sinkron — jalankan: sudo systemctl restart 9remote"
  fi
  echo
  [ $bad -eq 0 ] && c_ok "semua pemeriksaan lolos" || c_warn "$bad pemeriksaan gagal"
  echo
  c_info "log terakhir:"
  tail -15 "${HOME}/9remote.log" 2>/dev/null | sed 's/^/      /' || echo "      (belum ada log)"
}

# ---- Mode: --clean ---------------------------------------------------------
do_clean() {
  hdr "Bersihkan"
  run "sudo -n systemctl disable --now 9remote"
  run "sudo -n rm -f '$UNIT'"
  run "sudo -n systemctl daemon-reload"
  run "sudo -n pkill -9 -f '/usr/bin/9remote start'"
  run "sudo -n pkill -9 -f 'ptyDaemon.cjs'"
  run "sudo -n pkill -9 -f 'cloudflared'"
  run "sudo -n npm uninstall -g 9remote"
  run "rm -rf '${HOME}/.9remote' '${HOME}/9remote.log'"
  run "sudo -n rm -rf '$RUNTIME'"
  echo; c_ok "selesai"
  c_warn "kunci permanen lama tidak bisa dipakai lagi setelah ~/.9remote dihapus"
}

# ---- Main ------------------------------------------------------------------
case "$MODE" in
  --status) do_status ;;
  --doctor) do_doctor ;;
  --otk)    step_access ;;
  --clean)  do_clean ;;
  --all|--dry-run)
    hdr "recover.sh — mode ${MODE}"
    [ "$DRY" = 0 ] && c_warn "sandbox bisa lahir ulang kapan saja; ini tidak membuatnya permanen"
    step_node && step_install && step_service && step_access
    echo
    c_ok "selesai. Cek kesehatan kapan saja: bash recover.sh --doctor"
    ;;
  -h|--help|help)
    sed -n '2,24p' "$0" | sed 's/^# \{0,1\}//'
    ;;
  *)
    c_no "mode tidak dikenal: $MODE"; echo "  coba: --help"; exit 1 ;;
esac
