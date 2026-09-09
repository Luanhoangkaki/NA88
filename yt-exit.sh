#!/usr/bin/env bash
set -Eeuo pipefail

VERSION="6.1.0"

YT_REPO_OWNER="${YT_REPO_OWNER:-Luanhoangkaki}"
YT_REPO_NAME="${YT_REPO_NAME:-NA88}"
YT_REPO_REF="${YT_REPO_REF:-main}"
YT_GH_ENV="/etc/yt-manager/github.env"

load_gh_token(){
  if [[ -z "${GH_TOKEN:-}" && -f "$YT_GH_ENV" ]]; then
    source "$YT_GH_ENV"
  fi
}

need_gh_token(){
  load_gh_token
  [[ -n "${GH_TOKEN:-}" ]] || die "Chưa có GitHub token. Chạy lệnh yt rồi vào mục GitHub token."
}

gh_raw_download(){
  local path="$1" out="$2"
  need_gh_token
  curl -4fsSL --retry 3 --connect-timeout 10     -H "Authorization: Bearer $GH_TOKEN"     -H "Accept: application/vnd.github.raw+json"     "https://api.github.com/repos/${YT_REPO_OWNER}/${YT_REPO_NAME}/contents/${path}?ref=${YT_REPO_REF}"     -o "$out"
}

gh_release_asset_download(){
  local asset_name="$1" out="$2"
  need_gh_token
  local meta="/tmp/yt-release.$$.json" asset_id
  curl -4fsSL --retry 3 --connect-timeout 10     -H "Authorization: Bearer $GH_TOKEN"     -H "Accept: application/vnd.github+json"     "https://api.github.com/repos/${YT_REPO_OWNER}/${YT_REPO_NAME}/releases/latest"     -o "$meta" || { rm -f "$meta"; die "Không đọc được GitHub Release latest."; }

  asset_id="$(python3 - "$meta" "$asset_name" <<'PY'
import json,sys
data=json.load(open(sys.argv[1]))
name=sys.argv[2]
for a in data.get("assets",[]):
    if a.get("name")==name:
        print(a.get("id",""))
        break
PY
)"
  rm -f "$meta"
  [[ -n "$asset_id" ]] || die "Không thấy Release asset: $asset_name"

  curl -4fL --retry 3 --connect-timeout 10     -H "Authorization: Bearer $GH_TOKEN"     -H "Accept: application/octet-stream"     "https://api.github.com/repos/${YT_REPO_OWNER}/${YT_REPO_NAME}/releases/assets/${asset_id}"     -o "$out" || die "Không tải được Release asset: $asset_name"
}

SELF_URL="https://raw.githubusercontent.com/Luanhoangkaki/NA88/main/yt-exit.sh"

WG_IF="ytwg0"
WG_DIR="/etc/wireguard"
WG_CONF="$WG_DIR/${WG_IF}.conf"
STATE_DIR="/etc/yt-exit"
STATE_FILE="$STATE_DIR/state.env"
PEER_DIR="$STATE_DIR/peers"
SYSCTL_FILE="/etc/sysctl.d/99-yt-exit.conf"

DEFAULT_PORT="44443"
DEFAULT_EXIT_IP="10.88.0.1"
DEFAULT_PREFIX="24"
DEFAULT_MTU="1380"

GREEN='\033[32m'; YELLOW='\033[33m'; RED='\033[31m'; CYAN='\033[36m'; RESET='\033[0m'
ok(){ echo -e "${GREEN}[OK]${RESET} $*"; }
info(){ echo -e "${CYAN}[INFO]${RESET} $*"; }
warn(){ echo -e "${YELLOW}[WARN]${RESET} $*"; }
die(){ echo -e "${RED}[ERROR]${RESET} $*" >&2; exit 1; }

need_root(){ [[ ${EUID:-$(id -u)} -eq 0 ]] || die "Hãy chạy bằng root."; }
load_state(){ [[ -f "$STATE_FILE" ]] || return 1; source "$STATE_FILE"; }
detect_out_if(){ ip -4 route show default | awk 'NR==1 {for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}'; }
default_route(){ ip -4 route show default | head -1; }
public_ip(){ curl -4fsS --max-time 6 https://api.ipify.org 2>/dev/null || curl -4fsS --max-time 6 https://ifconfig.me 2>/dev/null || true; }

install_deps(){
  command -v apt-get >/dev/null 2>&1 || die "Chỉ hỗ trợ Debian/Ubuntu."
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq
  apt-get install -y -qq wireguard-tools iptables iproute2 curl >/dev/null
}

check_exit_subnet_collision(){
  local pfx existing
  pfx="${EXIT_TUN_IP%.*}"
  existing="$(ip -4 route show | grep -E "(^| )${pfx}\.0/${PREFIX}( |$)" || true)"
  if [[ -n "$existing" ]]; then
    die "Subnet ${pfx}.0/${PREFIX} đang được dùng: $existing"
  fi
  if ip -4 addr show | grep -Eq "inet ${EXIT_TUN_IP}/"; then
    die "EXIT tunnel IP $EXIT_TUN_IP đã tồn tại trên VPS."
  fi
}

save_state(){
  mkdir -p "$STATE_DIR" "$PEER_DIR"
  chmod 700 "$STATE_DIR" "$PEER_DIR"
  cat >"$STATE_FILE" <<EOF
WG_IF='$WG_IF'
WG_PORT='$WG_PORT'
EXIT_TUN_IP='$EXIT_TUN_IP'
PREFIX='$PREFIX'
WG_MTU='$WG_MTU'
OUT_IF='$OUT_IF'
PUBLIC_IP='$PUBLIC_IP'
DEFAULT_ROUTE_BEFORE='${DEFAULT_ROUTE_BEFORE//\'/}'
IP_FORWARD_BEFORE='$IP_FORWARD_BEFORE'
EOF
  chmod 600 "$STATE_FILE"
}

rebuild_conf(){
  load_state || die "Chưa cài yt-exit."
  local priv
  priv="$(cat "$STATE_DIR/private.key")"
  cat >"$WG_CONF" <<EOF
[Interface]
Address = ${EXIT_TUN_IP}/${PREFIX}
MTU = ${WG_MTU}
ListenPort = ${WG_PORT}
PrivateKey = ${priv}
SaveConfig = false

PostUp = iptables -C FORWARD -i %i -o ${OUT_IF} -j ACCEPT 2>/dev/null || iptables -A FORWARD -i %i -o ${OUT_IF} -j ACCEPT
PostUp = iptables -C FORWARD -i ${OUT_IF} -o %i -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || iptables -A FORWARD -i ${OUT_IF} -o %i -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
PostUp = iptables -t nat -C POSTROUTING -s ${EXIT_TUN_IP%.*}.0/${PREFIX} -o ${OUT_IF} -j MASQUERADE 2>/dev/null || iptables -t nat -A POSTROUTING -s ${EXIT_TUN_IP%.*}.0/${PREFIX} -o ${OUT_IF} -j MASQUERADE
PostDown = iptables -D FORWARD -i %i -o ${OUT_IF} -j ACCEPT 2>/dev/null || true
PostDown = iptables -D FORWARD -i ${OUT_IF} -o %i -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || true
PostDown = iptables -t nat -D POSTROUTING -s ${EXIT_TUN_IP%.*}.0/${PREFIX} -o ${OUT_IF} -j MASQUERADE 2>/dev/null || true
EOF
  if compgen -G "$PEER_DIR/*.conf" >/dev/null; then
    for f in "$PEER_DIR"/*.conf; do
      echo >>"$WG_CONF"; cat "$f" >>"$WG_CONF"
    done
  fi
  chmod 600 "$WG_CONF"
}

reload_wg(){
  if systemctl is-active --quiet "wg-quick@${WG_IF}"; then
    wg syncconf "$WG_IF" <(wg-quick strip "$WG_IF")
  else
    systemctl start "wg-quick@${WG_IF}"
  fi
}

cmd_install(){
  need_root; install_deps
  if [[ -f "$STATE_FILE" ]]; then warn "yt-exit đã được cài."; cmd_info; return 0; fi

  OUT_IF="$(detect_out_if)"
  [[ -n "$OUT_IF" ]] || die "Không phát hiện default interface."
  DEFAULT_ROUTE_BEFORE="$(default_route)"
  PUBLIC_IP="$(public_ip)"
  IP_FORWARD_BEFORE="$(sysctl -n net.ipv4.ip_forward 2>/dev/null || echo 0)"
  [[ "$PUBLIC_IP" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || warn "Không tự xác định được Public IPv4; lệnh info sẽ hiện unknown."

  read -rp "WireGuard port [${DEFAULT_PORT}]: " WG_PORT
  WG_PORT="${WG_PORT:-$DEFAULT_PORT}"
  read -rp "EXIT tunnel IP [${DEFAULT_EXIT_IP}]: " EXIT_TUN_IP
  EXIT_TUN_IP="${EXIT_TUN_IP:-$DEFAULT_EXIT_IP}"
  PREFIX="$DEFAULT_PREFIX"
  WG_MTU="${YT_WG_MTU:-$DEFAULT_MTU}"

  [[ "$WG_PORT" =~ ^[0-9]+$ ]] && (( WG_PORT >= 1 && WG_PORT <= 65535 )) || die "WireGuard port không hợp lệ."
  [[ "$EXIT_TUN_IP" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "EXIT tunnel IP không hợp lệ."
  [[ "$WG_MTU" =~ ^[0-9]+$ ]] && (( WG_MTU >= 1280 && WG_MTU <= 1500 )) || die "MTU không hợp lệ (1280-1500)."

  check_exit_subnet_collision

  ss -Hlun 2>/dev/null | awk '{print $5}' | grep -Eq "[:.]${WG_PORT}$" && die "UDP port $WG_PORT đang được sử dụng."
  ip link show "$WG_IF" >/dev/null 2>&1 && die "Interface $WG_IF đã tồn tại."
  [[ ! -f /etc/yt-main/state.env ]] || die "VPS này đang cài yt-main."
  ip route show table 188 2>/dev/null | grep -q . && warn "Routing table 188 đang có dữ liệu; EXIT không dùng table này nhưng hãy kiểm tra hệ thống."

  mkdir -p "$WG_DIR" "$STATE_DIR" "$PEER_DIR"
  chmod 700 "$WG_DIR" "$STATE_DIR" "$PEER_DIR"

  local priv pub
  priv="$(wg genkey)"
  pub="$(printf '%s' "$priv" | wg pubkey)"
  printf '%s\n' "$priv" >"$STATE_DIR/private.key"
  printf '%s\n' "$pub" >"$STATE_DIR/public.key"
  chmod 600 "$STATE_DIR/private.key"; chmod 644 "$STATE_DIR/public.key"

  save_state; rebuild_conf
  echo 'net.ipv4.ip_forward=1' >"$SYSCTL_FILE"
  sysctl -p "$SYSCTL_FILE" >/dev/null

  systemctl enable --now "wg-quick@${WG_IF}" >/dev/null
  sleep 1

  [[ "$(default_route)" == "$DEFAULT_ROUTE_BEFORE" ]] || {
    systemctl disable --now "wg-quick@${WG_IF}" >/dev/null 2>&1 || true
    die "Default route bị thay đổi. Đã dừng WireGuard."
  }

  ok "VPS EXIT đã sẵn sàng."
  cmd_info
}

cmd_info(){
  need_root; load_state || die "Chưa cài yt-exit."
  echo
  echo "===== YT EXIT INFO ====="
  echo "Public IP : ${PUBLIC_IP:-unknown}"
  echo "Public Key: $(cat "$STATE_DIR/public.key")"
  echo "Port      : $WG_PORT"
  echo "Tunnel IP : $EXIT_TUN_IP"
  echo "Interface : $WG_IF"
  echo "Out IF    : $OUT_IF"
}

next_ip(){
  load_state || die "Chưa cài yt-exit."
  local prefix used i
  prefix="${EXIT_TUN_IP%.*}"
  used="$(grep -h '^AllowedIPs' "$PEER_DIR"/*.conf 2>/dev/null | sed -E 's/.*= *([^/]+).*/\1/' || true)"
  for i in $(seq 2 254); do
    if ! grep -qx "${prefix}.${i}" <<<"$used"; then echo "${prefix}.${i}"; return; fi
  done
  die "Không còn IP tunnel trống."
}

safe_name(){ tr -cd 'A-Za-z0-9_.-' <<<"$1"; }

cmd_add(){
  need_root; load_state || die "Chưa cài yt-exit."
  local name="${1:-}" pubkey="${2:-}" ip="${3:-}"
  [[ -n "$name" ]] || read -rp "Tên VPS MAIN: " name
  [[ -n "$pubkey" ]] || read -rp "Public Key của VPS MAIN: " pubkey
  name="$(safe_name "$name")"
  [[ -n "$name" ]] || die "Tên MAIN không hợp lệ."
  [[ "$pubkey" =~ ^[A-Za-z0-9+/]{42,44}=$ ]] || die "Public Key không hợp lệ."
  [[ -n "$ip" ]] || ip="$(next_ip)"
  ip="${ip%/32}"
  [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "Tunnel IP MAIN không hợp lệ."
  [[ "${ip%.*}" == "${EXIT_TUN_IP%.*}" ]] || die "MAIN tunnel IP phải cùng subnet /24 với EXIT."
  [[ "$ip" != "$EXIT_TUN_IP" ]] || die "MAIN không được dùng cùng tunnel IP với EXIT."

  grep -R -Fq "$pubkey" "$PEER_DIR" 2>/dev/null && die "Public Key đã tồn tại."
  grep -R -Fq "AllowedIPs = ${ip}/32" "$PEER_DIR" 2>/dev/null && die "Tunnel IP đã được dùng."

  cat >"$PEER_DIR/${name}.conf" <<EOF
# MAIN: $name
[Peer]
PublicKey = $pubkey
AllowedIPs = ${ip}/32
EOF
  chmod 600 "$PEER_DIR/${name}.conf"

  rebuild_conf; reload_wg
  ok "Đã thêm $name."
  echo "MAIN_TUNNEL_IP=$ip"
  echo "Trên VPS MAIN chạy: yt-main activate $ip"
}

cmd_remove(){
  need_root; load_state || die "Chưa cài yt-exit."
  local name="${1:-}"
  [[ -n "$name" ]] || read -rp "Tên MAIN cần xóa: " name
  name="$(safe_name "$name")"
  [[ -f "$PEER_DIR/${name}.conf" ]] || die "Không tìm thấy MAIN $name."
  rm -f "$PEER_DIR/${name}.conf"
  rebuild_conf; reload_wg
  ok "Đã xóa $name."
}

cmd_list(){
  need_root; load_state || die "Chưa cài yt-exit."
  echo "===== MAIN PEERS ====="
  if ! compgen -G "$PEER_DIR/*.conf" >/dev/null; then echo "Chưa có MAIN."; return; fi
  for f in "$PEER_DIR"/*.conf; do
    echo "--- $(basename "$f" .conf) ---"
    grep -E '^(PublicKey|AllowedIPs)' "$f"
  done
}

cmd_status(){
  need_root; load_state || die "Chưa cài yt-exit."
  echo "===== SERVICE ====="
  systemctl is-enabled "wg-quick@${WG_IF}" 2>/dev/null || true
  systemctl is-active "wg-quick@${WG_IF}" 2>/dev/null || true
  echo; echo "===== DEFAULT ROUTE ====="; default_route
  echo; echo "===== WG ====="; wg show "$WG_IF" 2>/dev/null || true
  echo; echo "===== FORWARD/NAT ====="
  sysctl net.ipv4.ip_forward
  iptables -t nat -S POSTROUTING | grep -F "${EXIT_TUN_IP%.*}.0/${PREFIX}" || true
}

cmd_test(){
  need_root; load_state || die "Chưa cài yt-exit."
  local fail=0 current_if
  systemctl is-active --quiet "wg-quick@${WG_IF}" && ok "WireGuard active" || { warn "WireGuard inactive"; fail=1; }
  [[ "$(sysctl -n net.ipv4.ip_forward)" == "1" ]] && ok "ip_forward=1" || { warn "ip_forward sai"; fail=1; }
  current_if="$(detect_out_if)"
  [[ "$current_if" == "$OUT_IF" ]] && ok "Default interface vẫn là $OUT_IF" || { warn "Default interface đổi thành $current_if"; fail=1; }
  iptables -t nat -S POSTROUTING | grep -Fq "${EXIT_TUN_IP%.*}.0/${PREFIX}" && ok "NAT tồn tại" || { warn "NAT thiếu"; fail=1; }

  if compgen -G "$PEER_DIR/*.conf" >/dev/null; then
    if wg show "$WG_IF" latest-handshakes 2>/dev/null | awk '$2 > 0 {ok=1} END{exit !ok}'; then
      ok "Có MAIN đã handshake"
    else
      warn "Đã có MAIN nhưng chưa thấy handshake"
      fail=1
    fi
  fi
  return "$fail"
}

cmd_uninstall(){
  need_root; load_state || true
  warn "Đang gỡ yt-exit..."
  systemctl disable --now "wg-quick@${WG_IF}" >/dev/null 2>&1 || true
  rm -f "$WG_CONF" "$SYSCTL_FILE"
  if [[ -n "${IP_FORWARD_BEFORE:-}" ]]; then
    sysctl -w "net.ipv4.ip_forward=${IP_FORWARD_BEFORE}" >/dev/null 2>&1 || true
  fi
  rm -rf "$STATE_DIR"
  ok "Đã gỡ yt-exit và khôi phục ip_forward trước khi cài."
}


cmd_version(){
  echo "YT EXIT v${VERSION}"
}

cmd_update(){
  need_root
  local tmp="/tmp/yt-exit.sh.$$"
  info "Đang tải yt-exit mới từ Git private..."
  gh_raw_download "yt-exit.sh" "$tmp"
  bash -n "$tmp" || { rm -f "$tmp"; die "File mới lỗi cú pháp."; }
  install -m 755 "$tmp" /usr/local/lib/yt-manager/yt-exit.sh
  rm -f "$tmp"
  ok "Đã cập nhật yt-exit."
}

menu(){
  while true; do
    clear 2>/dev/null || true
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "       YT EXIT v${VERSION}"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    printf "WG : "
    systemctl is-active --quiet "wg-quick@${WG_IF}" 2>/dev/null && echo "ACTIVE" || echo "OFF"
    echo
    echo "1) Cài EXIT"
    echo "2) Thông tin"
    echo "3) Thêm MAIN"
    echo "4) Xóa MAIN"
    echo "5) Danh sách MAIN"
    echo "6) Trạng thái"
    echo "7) Kiểm tra"
    echo "8) Cập nhật lệnh"
    echo "9) Gỡ"
    echo "0) Thoát"
    echo
    read -rp "Chọn: " c
    case "$c" in
      1)
        if [[ -f "$STATE_FILE" ]]; then
          ok "YT EXIT đã được cài."
          cmd_info || true
        else
          cmd_install || true
        fi
        ;;
      2) cmd_info || true ;;
      3) cmd_add || true ;;
      4) cmd_remove || true ;;
      5) cmd_list || true ;;
      6) cmd_status || true ;;
      7) cmd_test || true ;;
      8) cmd_update || true ;;
      9)
        read -rp "Gỡ YT EXIT? [y/N]: " y
        [[ "$y" =~ ^[Yy]$ ]] && cmd_uninstall || true
        ;;
      0) return 0 ;;
      *) warn "Lựa chọn không hợp lệ." ;;
    esac
    echo
    read -rp "Enter để tiếp tục..." _
  done
}

usage(){
  cat <<EOF
YT EXIT - VPS chuyên làm cổng ra YouTube

  yt-exit install
  yt-exit info
  yt-exit add [MAIN_NAME] [MAIN_PUBLIC_KEY] [MAIN_TUNNEL_IP]
  yt-exit remove [MAIN_NAME]
  yt-exit list
  yt-exit status
  yt-exit test
  yt-exit update
  yt-exit version
  yt-exit uninstall
EOF
}

case "${1:-}" in
  "") menu ;;
  install) shift; cmd_install "$@" ;;
  info) shift; cmd_info "$@" ;;
  add) shift; cmd_add "$@" ;;
  remove) shift; cmd_remove "$@" ;;
  list) shift; cmd_list "$@" ;;
  status) shift; cmd_status "$@" ;;
  test) shift; cmd_test "$@" ;;
  update) shift; cmd_update "$@" ;;
  version) shift; cmd_version "$@" ;;
  uninstall) shift; cmd_uninstall "$@" ;;
  *) usage ;;
esac
