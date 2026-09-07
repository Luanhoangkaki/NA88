#!/usr/bin/env bash
# China Carrier Firewall
# Menu chặn China Telecom / China Unicom / China Mobile
# Debian 12/13 - IPv4 - ipset + iptables
#
# Chế độ:
#   cn-carrier-fw              -> menu tương tác
#   cn-carrier-fw --apply-saved -> cập nhật prefix và áp dụng cấu hình đã lưu
#   cn-carrier-fw --status      -> xem trạng thái
#   cn-carrier-fw --remove      -> gỡ toàn bộ rule do script tạo
#
set -Eeuo pipefail

APP="cn-carrier-fw"
INSTALL_PATH="/usr/local/sbin/cn-carrier-fw"
CONF_DIR="/etc/cn-carrier-fw"
CONF_FILE="$CONF_DIR/config"
IPSET_SAVE="$CONF_DIR/ipset.rules"

SET_NAME="cncfw_block"
SET_NEW="cncfw_block_new"
CHAIN_IN="CNCFW_INPUT"
CHAIN_OUT="CNCFW_OUTPUT"

RESTORE_SERVICE="cn-carrier-fw-restore.service"
UPDATE_SERVICE="cn-carrier-fw-update.service"
UPDATE_TIMER="cn-carrier-fw-update.timer"

# ----------------------------------------------------------------------
# ASN chính và ASN mạng tỉnh/thành thường gặp.
# Script tự cập nhật PREFIX đang được từng ASN công bố từ RIPEstat.
# Nếu sau này nhà mạng có ASN mới, chỉ cần bổ sung ASN vào nhóm tương ứng.
# ----------------------------------------------------------------------

TELECOM_ASNS=(
  4134    # China Telecom Backbone
  4809    # China Telecom CN2
  4811    # China Telecom Group
  4812    # China Telecom Group
  4816    # China Telecom
  23724   # China Telecom IDC
  23764   # CTGNet / China Telecom Global
)

UNICOM_ASNS=(
  4837    # China Unicom Backbone / China169
  9929    # China Netcom Backbone
  4808    # China Unicom Beijing
  17621   # China Unicom Shanghai
  17622   # China Unicom Guangzhou
  17623   # China Unicom Shenzhen
  17816   # China Unicom Guangdong
  136958  # China Unicom Guangdong IP network
  140726  # China Unicom Anhui
  10099   # China Unicom Global
)

MOBILE_ASNS=(
  9808    # China Mobile backbone
  56040
  56041
  56042
  56044
  56046
  56047
  56048
  24400   # Shanghai Mobile
  24444   # Shandong Mobile
)

log()  { printf '\033[1;32m%s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m%s\033[0m\n' "$*" >&2; }
err()  { printf '\033[1;31m%s\033[0m\n' "$*" >&2; }

need_root() {
  if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
    err "Vui lòng chạy bằng root."
    exit 1
  fi
}

install_packages() {
  export DEBIAN_FRONTEND=noninteractive
  local missing=0
  for c in curl jq ipset iptables flock; do
    command -v "$c" >/dev/null 2>&1 || missing=1
  done

  if [[ "$missing" -eq 1 ]] || ! dpkg -s iptables-persistent >/dev/null 2>&1; then
    log "[+] Cài gói cần thiết..."
    apt-get update -qq
    apt-get install -y -qq curl jq ipset iptables iptables-persistent util-linux >/dev/null
  fi
}

install_self() {
  mkdir -p "$CONF_DIR"
  if [[ "$(readlink -f "$0")" != "$INSTALL_PATH" ]]; then
    cp -f "$0" "$INSTALL_PATH"
    chmod 700 "$INSTALL_PATH"
  fi
}

save_choice() {
  local choice="$1"
  mkdir -p "$CONF_DIR"
  cat >"$CONF_FILE" <<EOF
CHOICE="$choice"
EOF
  chmod 600 "$CONF_FILE"
}

load_choice() {
  if [[ ! -f "$CONF_FILE" ]]; then
    err "Chưa có cấu hình đã lưu. Hãy chạy: $INSTALL_PATH"
    exit 1
  fi
  # shellcheck disable=SC1090
  source "$CONF_FILE"
  if [[ -z "${CHOICE:-}" ]]; then
    err "File cấu hình không hợp lệ."
    exit 1
  fi
}

choice_description() {
  case "$1" in
    1) echo "Chặn China Telecom" ;;
    2) echo "Chặn China Unicom" ;;
    3) echo "Chặn China Mobile" ;;
    4) echo "Chặn China Telecom + China Unicom (chỉ để China Mobile)" ;;
    5) echo "Chặn China Telecom + China Mobile (chỉ để China Unicom)" ;;
    6) echo "Chặn China Unicom + China Mobile (chỉ để China Telecom)" ;;
    *) echo "Không xác định" ;;
  esac
}

build_asn_list() {
  local choice="$1"
  SELECTED_ASNS=()
  case "$choice" in
    1) SELECTED_ASNS=("${TELECOM_ASNS[@]}") ;;
    2) SELECTED_ASNS=("${UNICOM_ASNS[@]}") ;;
    3) SELECTED_ASNS=("${MOBILE_ASNS[@]}") ;;
    4) SELECTED_ASNS=("${TELECOM_ASNS[@]}" "${UNICOM_ASNS[@]}") ;;
    5) SELECTED_ASNS=("${TELECOM_ASNS[@]}" "${MOBILE_ASNS[@]}") ;;
    6) SELECTED_ASNS=("${UNICOM_ASNS[@]}" "${MOBILE_ASNS[@]}") ;;
    *)
      err "Lựa chọn không hợp lệ: $choice"
      exit 1
      ;;
  esac
}

fetch_prefixes() {
  local choice="$1"
  local tmpdir outfile asn
  tmpdir="$(mktemp -d)"
  outfile="$tmpdir/prefixes.txt"
  : >"$outfile"
  trap 'rm -rf "${tmpdir:-}"' RETURN

  build_asn_list "$choice"

  log "[+] Cập nhật IPv4 prefix từ RIPEstat..."
  for asn in "${SELECTED_ASNS[@]}"; do
    printf '    AS%s ... ' "$asn"
    if curl --connect-timeout 8 --max-time 30 --retry 2 -fsSL \
      "https://stat.ripe.net/data/announced-prefixes/data.json?resource=AS${asn}" \
      | jq -r '.data.prefixes[]?.prefix' \
      | grep -Fv ':' >>"$outfile"; then
      echo "OK"
    else
      echo "LỖI"
    fi
  done

  sort -u "$outfile" -o "$outfile"
  PREFIX_COUNT="$(grep -c . "$outfile" || true)"

  # Không thay firewall nếu nguồn dữ liệu lỗi nghiêm trọng.
  if (( PREFIX_COUNT < 100 )); then
    err "Chỉ lấy được $PREFIX_COUNT prefix. Giữ nguyên firewall cũ để tránh chặn sai."
    exit 1
  fi

  PREFIX_FILE="$CONF_DIR/prefixes.new"
  cp -f "$outfile" "$PREFIX_FILE"
  log "[+] Tổng prefix IPv4: $PREFIX_COUNT"
}

update_ipset_atomic() {
  ipset destroy "$SET_NEW" 2>/dev/null || true
  ipset create "$SET_NEW" hash:net family inet hashsize 131072 maxelem 1000000

  # ipset restore nhanh hơn gọi ipset add từng dòng.
  {
    while IFS= read -r net; do
      [[ -n "$net" ]] && printf 'add %s %s -exist\n' "$SET_NEW" "$net"
    done <"$PREFIX_FILE"
  } | ipset restore

  ipset create "$SET_NAME" hash:net family inet hashsize 131072 maxelem 1000000 -exist
  ipset swap "$SET_NEW" "$SET_NAME"
  ipset destroy "$SET_NEW"

  rm -f "$PREFIX_FILE"
}

ensure_jump_once() {
  local parent="$1" child="$2"
  while iptables -C "$parent" -j "$child" >/dev/null 2>&1; do
    iptables -D "$parent" -j "$child"
  done
  iptables -I "$parent" 1 -j "$child"
}

apply_iptables() {
  iptables -N "$CHAIN_IN" 2>/dev/null || true
  iptables -F "$CHAIN_IN"
  iptables -A "$CHAIN_IN" -m set --match-set "$SET_NAME" src -j DROP

  iptables -N "$CHAIN_OUT" 2>/dev/null || true
  iptables -F "$CHAIN_OUT"
  iptables -A "$CHAIN_OUT" -m set --match-set "$SET_NAME" dst -j DROP

  ensure_jump_once INPUT "$CHAIN_IN"
  ensure_jump_once OUTPUT "$CHAIN_OUT"

  # Dọn các chain cũ của bản thử trước đây nếu có.
  while iptables -C INPUT -j CN_CARRIER_BLOCK >/dev/null 2>&1; do
    iptables -D INPUT -j CN_CARRIER_BLOCK || true
  done
  while iptables -C OUTPUT -j CN_CARRIER_BLOCK_OUT >/dev/null 2>&1; do
    iptables -D OUTPUT -j CN_CARRIER_BLOCK_OUT || true
  done
  iptables -F CN_CARRIER_BLOCK 2>/dev/null || true
  iptables -X CN_CARRIER_BLOCK 2>/dev/null || true
  iptables -F CN_CARRIER_BLOCK_OUT 2>/dev/null || true
  iptables -X CN_CARRIER_BLOCK_OUT 2>/dev/null || true
}

save_persistence() {
  mkdir -p "$CONF_DIR"
  ipset save "$SET_NAME" >"$IPSET_SAVE"

  cat >"/etc/systemd/system/$RESTORE_SERVICE" <<EOF
[Unit]
Description=Restore China Carrier Firewall ipset
DefaultDependencies=no
After=local-fs.target
Before=netfilter-persistent.service
Wants=netfilter-persistent.service

[Service]
Type=oneshot
ExecStart=/bin/sh -c '/sbin/ipset restore -exist < $IPSET_SAVE'
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

  cat >"/etc/systemd/system/$UPDATE_SERVICE" <<EOF
[Unit]
Description=Update China Carrier Firewall prefixes
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=$INSTALL_PATH --apply-saved
TimeoutStartSec=10min
EOF

  cat >"/etc/systemd/system/$UPDATE_TIMER" <<'EOF'
[Unit]
Description=Daily China Carrier Firewall prefix update

[Timer]
OnBootSec=15min
OnUnitActiveSec=24h
RandomizedDelaySec=15min
Persistent=true

[Install]
WantedBy=timers.target
EOF

  systemctl daemon-reload
  systemctl enable "$RESTORE_SERVICE" >/dev/null 2>&1 || true
  systemctl enable --now "$UPDATE_TIMER" >/dev/null 2>&1 || true
  netfilter-persistent save >/dev/null 2>&1 || true
}

apply_choice() {
  local choice="$1"
  fetch_prefixes "$choice"
  update_ipset_atomic
  apply_iptables
  save_choice "$choice"
  save_persistence

  echo
  log "=============================================="
  log " HOÀN TẤT"
  log " $(choice_description "$choice")"
  log " Prefix IPv4: $PREFIX_COUNT"
  log " Tự cập nhật: mỗi 24 giờ"
  log "=============================================="
}

remove_all() {
  log "[+] Gỡ China Carrier Firewall..."

  while iptables -C INPUT -j "$CHAIN_IN" >/dev/null 2>&1; do
    iptables -D INPUT -j "$CHAIN_IN" || true
  done
  while iptables -C OUTPUT -j "$CHAIN_OUT" >/dev/null 2>&1; do
    iptables -D OUTPUT -j "$CHAIN_OUT" || true
  done
  iptables -F "$CHAIN_IN" 2>/dev/null || true
  iptables -X "$CHAIN_IN" 2>/dev/null || true
  iptables -F "$CHAIN_OUT" 2>/dev/null || true
  iptables -X "$CHAIN_OUT" 2>/dev/null || true

  # Dọn bản cũ nếu từng cài.
  while iptables -C INPUT -j CN_CARRIER_BLOCK >/dev/null 2>&1; do
    iptables -D INPUT -j CN_CARRIER_BLOCK || true
  done
  while iptables -C OUTPUT -j CN_CARRIER_BLOCK_OUT >/dev/null 2>&1; do
    iptables -D OUTPUT -j CN_CARRIER_BLOCK_OUT || true
  done
  iptables -F CN_CARRIER_BLOCK 2>/dev/null || true
  iptables -X CN_CARRIER_BLOCK 2>/dev/null || true
  iptables -F CN_CARRIER_BLOCK_OUT 2>/dev/null || true
  iptables -X CN_CARRIER_BLOCK_OUT 2>/dev/null || true

  ipset destroy "$SET_NEW" 2>/dev/null || true
  ipset destroy "$SET_NAME" 2>/dev/null || true
  ipset destroy cn_ut_block 2>/dev/null || true

  systemctl disable --now "$UPDATE_TIMER" >/dev/null 2>&1 || true
  systemctl disable "$RESTORE_SERVICE" >/dev/null 2>&1 || true

  rm -f \
    "/etc/systemd/system/$RESTORE_SERVICE" \
    "/etc/systemd/system/$UPDATE_SERVICE" \
    "/etc/systemd/system/$UPDATE_TIMER" \
    "$CONF_FILE" "$IPSET_SAVE" "$CONF_DIR/prefixes.new"

  systemctl daemon-reload
  netfilter-persistent save >/dev/null 2>&1 || true

  log "[+] Đã gỡ toàn bộ rule do script tạo."
}

show_status() {
  echo "=============================================="
  echo " CHINA CARRIER FIREWALL - TRẠNG THÁI"
  echo "=============================================="

  if [[ -f "$CONF_FILE" ]]; then
    # shellcheck disable=SC1090
    source "$CONF_FILE"
    echo "Cấu hình: $(choice_description "${CHOICE:-0}")"
  else
    echo "Cấu hình: chưa lưu"
  fi

  if ipset list "$SET_NAME" >/dev/null 2>&1; then
    ipset list "$SET_NAME" | grep -E '^(Name:|Number of entries:|Size in memory:)'
  else
    echo "IPSet: chưa tồn tại"
  fi

  echo
  iptables -L "$CHAIN_IN" -n -v 2>/dev/null || true
  echo
  iptables -L "$CHAIN_OUT" -n -v 2>/dev/null || true
  echo
  systemctl list-timers "$UPDATE_TIMER" --no-pager 2>/dev/null || true
}

menu() {
  while true; do
    clear 2>/dev/null || true
    cat <<'EOF'
==================================================
        CHINA CARRIER FIREWALL
==================================================

Chọn NHÀ MẠNG MUỐN CHẶN:

  1) China Telecom
  2) China Unicom
  3) China Mobile

  4) China Telecom + China Unicom
     -> Chỉ để China Mobile

  5) China Telecom + China Mobile
     -> Chỉ để China Unicom

  6) China Unicom + China Mobile
     -> Chỉ để China Telecom

  7) Xem trạng thái
  8) Cập nhật lại prefix ngay
  9) Gỡ toàn bộ chặn

  0) Thoát

==================================================
EOF

    read -r -p "Nhập lựa chọn [0-9]: " choice

    case "$choice" in
      1|2|3|4|5|6)
        echo
        warn "Bạn chọn: $(choice_description "$choice")"
        warn "LƯU Ý: nếu IP SSH hiện tại thuộc nhà mạng bị chặn, kết nối có thể bị ngắt."
        read -r -p "Tiếp tục? [y/N]: " confirm
        [[ "$confirm" =~ ^[Yy]$ ]] && apply_choice "$choice"
        read -r -p "Nhấn Enter để quay lại menu..." _
        ;;
      7)
        show_status
        read -r -p "Nhấn Enter để quay lại menu..." _
        ;;
      8)
        if [[ -f "$CONF_FILE" ]]; then
          load_choice
          apply_choice "$CHOICE"
        else
          warn "Chưa có lựa chọn được lưu."
        fi
        read -r -p "Nhấn Enter để quay lại menu..." _
        ;;
      9)
        warn "Thao tác này sẽ gỡ toàn bộ chặn China Carrier Firewall."
        read -r -p "Gõ YES để xác nhận: " confirm
        [[ "$confirm" == "YES" ]] && remove_all
        read -r -p "Nhấn Enter để quay lại menu..." _
        ;;
      0)
        exit 0
        ;;
      *)
        warn "Lựa chọn không hợp lệ."
        sleep 1
        ;;
    esac
  done
}

main() {
  need_root

  # Tránh timer và thao tác tay cập nhật cùng lúc.
  exec 9>"$CONF_DIR.lock"
  if ! flock -n 9; then
    err "Một tiến trình $APP khác đang chạy. Hãy thử lại sau."
    exit 1
  fi

  install_packages
  install_self

  case "${1:-}" in
    --apply-saved)
      load_choice
      apply_choice "$CHOICE"
      ;;
    --status)
      show_status
      ;;
    --remove)
      remove_all
      ;;
    --help|-h)
      cat <<EOF
$APP
  Không tham số      Mở menu
  --apply-saved      Cập nhật prefix và áp dụng cấu hình đã lưu
  --status           Xem trạng thái
  --remove           Gỡ toàn bộ rule
EOF
      ;;
    "")
      menu
      ;;
    *)
      err "Tham số không hợp lệ: $1"
      exit 1
      ;;
  esac
}

main "$@"
