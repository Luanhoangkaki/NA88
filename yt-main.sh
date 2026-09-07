#!/usr/bin/env bash
set -Eeuo pipefail

VERSION="4.1.0"
SELF_URL="https://raw.githubusercontent.com/Luanhoangkaki/NA88/main/yt-main.sh"

WG_IF="ytwg0"
WG_DIR="/etc/wireguard"
WG_CONF="$WG_DIR/${WG_IF}.conf"
STATE_DIR="/etc/yt-main"
STATE_FILE="$STATE_DIR/state.env"
ASSET_DIR="/opt/yt-main"
CUSTOM_BIN="$ASSET_DIR/v2node-youtube-final"
V2NODE_BIN="/usr/local/v2node/v2node"
V2NODE_SERVICE="v2node"
DROPIN_DIR="/etc/systemd/system/v2node.service.d"
DROPIN_FILE="$DROPIN_DIR/20-yt-main.conf"
ROUTE_SCRIPT="/usr/local/sbin/yt-main-route.sh"
ROUTE_SERVICE="/etc/systemd/system/yt-main-route.service"
TABLE_ID="188"
RULE_PRIO="1000"
DEFAULT_MTU="1380"

DEFAULT_BINARY_URL="https://github.com/Luanhoangkaki/NA88/releases/latest/download/v2node-youtube-final.gz"
DEFAULT_SHA_URL="https://github.com/Luanhoangkaki/NA88/releases/latest/download/v2node-youtube-final.gz.sha256"

GREEN='\033[32m'; YELLOW='\033[33m'; RED='\033[31m'; CYAN='\033[36m'; RESET='\033[0m'
ok(){ echo -e "${GREEN}[OK]${RESET} $*"; }
info(){ echo -e "${CYAN}[INFO]${RESET} $*"; }
warn(){ echo -e "${YELLOW}[WARN]${RESET} $*"; }
die(){ echo -e "${RED}[ERROR]${RESET} $*" >&2; exit 1; }

need_root(){ [[ ${EUID:-$(id -u)} -eq 0 ]] || die "Hãy chạy bằng root."; }
default_route(){ ip -4 route show default | head -1; }
detect_out_if(){ ip -4 route show default | awk 'NR==1 {for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}'; }
load_state(){ [[ -f "$STATE_FILE" ]] || return 1; source "$STATE_FILE"; }

install_deps(){
  command -v apt-get >/dev/null 2>&1 || die "Chỉ hỗ trợ Debian/Ubuntu."
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq
  apt-get install -y -qq wireguard-tools iproute2 curl gzip >/dev/null
}

check_v2node(){
  [[ -x "$V2NODE_BIN" ]] || die "Không thấy $V2NODE_BIN"
  systemctl cat "$V2NODE_SERVICE" >/dev/null 2>&1 || die "Không thấy v2node.service"
}

download_binary(){
  mkdir -p "$ASSET_DIR"
  local src="${1:-}" url="${YT_BINARY_URL:-$DEFAULT_BINARY_URL}"
  local sha_url="${YT_SHA_URL:-$DEFAULT_SHA_URL}"

  if [[ -n "$src" && -s "$src" ]]; then
    cp -a "$src" "$CUSTOM_BIN"
  elif [[ -s /root/v2node-youtube-final ]]; then
    cp -a /root/v2node-youtube-final "$CUSTOM_BIN"
  else
    info "Tải binary custom từ GitHub Release..."
    curl -4fL --retry 3 --connect-timeout 10 "$url" -o "$ASSET_DIR/v2node-youtube-final.gz" || \
      die "Không tải được binary."

    if curl -4fsSL --retry 2 --connect-timeout 10 "$sha_url" -o "$ASSET_DIR/v2node-youtube-final.gz.sha256"; then
      local expected actual
      expected="$(awk 'NR==1{print $1}' "$ASSET_DIR/v2node-youtube-final.gz.sha256")"
      actual="$(sha256sum "$ASSET_DIR/v2node-youtube-final.gz" | awk '{print $1}')"
      [[ "$expected" == "$actual" ]] || die "SHA256 binary tải về không khớp."
      ok "SHA256 asset hợp lệ."
    else
      die "Thiếu file checksum Release: v2node-youtube-final.gz.sha256"
    fi

    gzip -dc "$ASSET_DIR/v2node-youtube-final.gz" >"$CUSTOM_BIN"
  fi

  chmod 755 "$CUSTOM_BIN"
  "$CUSTOM_BIN" version >/dev/null 2>&1 || die "Binary custom không chạy được."
  sha256sum "$CUSTOM_BIN" | awk '{print $1}' >"$ASSET_DIR/custom.sha256"
}
save_state(){
  mkdir -p "$STATE_DIR"; chmod 700 "$STATE_DIR"
  cat >"$STATE_FILE" <<EOF
WG_IF='$WG_IF'
EXIT_PUBLIC_IP='$EXIT_PUBLIC_IP'
EXIT_PUBLIC_KEY='$EXIT_PUBLIC_KEY'
EXIT_PORT='$EXIT_PORT'
EXIT_TUNNEL_IP='$EXIT_TUNNEL_IP'
OUT_IF='$OUT_IF'
DEFAULT_ROUTE_BEFORE='${DEFAULT_ROUTE_BEFORE//\'/}'
TABLE_ID='$TABLE_ID'
RULE_PRIO='$RULE_PRIO'
WG_MTU='$WG_MTU'
EOF
  chmod 600 "$STATE_FILE"
}

tunnel_prefix(){
  echo "$1" | awk -F. '{print $1"."$2"."$3}'
}

check_tunnel_collision(){
  local local_ip="$1"
  local pfx existing
  pfx="$(tunnel_prefix "$local_ip")"

  if ip -4 addr show | grep -Eq "inet ${local_ip}/"; then
    die "Tunnel IP $local_ip đã tồn tại trên VPS."
  fi

  existing="$(ip -4 route show | grep -E "(^| )${pfx}\.0/24( |$)" || true)"
  if [[ -n "$existing" ]]; then
    die "Subnet ${pfx}.0/24 đang được dùng: $existing"
  fi
}

make_wg_conf(){
  local priv="$1" local_ip="$2"
  mkdir -p "$WG_DIR"; chmod 700 "$WG_DIR"
  cat >"$WG_CONF" <<EOF
[Interface]
Address = ${local_ip}/24
MTU = ${WG_MTU}
PrivateKey = ${priv}
Table = off

[Peer]
PublicKey = ${EXIT_PUBLIC_KEY}
Endpoint = ${EXIT_PUBLIC_IP}:${EXIT_PORT}
AllowedIPs = 0.0.0.0/0
PersistentKeepalive = 25
EOF
  chmod 600 "$WG_CONF"
}

make_route_files(){
  local local_ip="$1"
  cat >"$ROUTE_SCRIPT" <<EOF
#!/usr/bin/env bash
set -e
WG_IF="$WG_IF"
SRC="$local_ip"
TABLE="$TABLE_ID"
PRIO="$RULE_PRIO"
ip link show "\$WG_IF" >/dev/null 2>&1 || exit 1
# Endpoint WireGuard luôn đi theo main table, tránh routing loop.
ip route get "$EXIT_PUBLIC_IP" >/dev/null 2>&1 || exit 1
while ip rule del from "\$SRC/32" table "\$TABLE" 2>/dev/null; do :; done
ip rule add from "\$SRC/32" table "\$TABLE" priority "\$PRIO"
ip route replace default dev "\$WG_IF" table "\$TABLE"
ip route flush cache 2>/dev/null || true
EOF
  chmod 755 "$ROUTE_SCRIPT"

  cat >"$ROUTE_SERVICE" <<EOF
[Unit]
Description=YT MAIN policy route
After=network-online.target wg-quick@${WG_IF}.service
Wants=network-online.target
Requires=wg-quick@${WG_IF}.service

[Service]
Type=oneshot
ExecStart=$ROUTE_SCRIPT
ExecStop=/bin/sh -c 'while ip rule del from ${local_ip}/32 table $TABLE_ID 2>/dev/null; do :; done; ip route flush table $TABLE_ID 2>/dev/null || true'
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
}

make_v2node_dropin(){
  local local_ip="$1"
  mkdir -p "$DROPIN_DIR"
  cat >"$DROPIN_FILE" <<EOF
[Unit]
After=wg-quick@${WG_IF}.service yt-main-route.service
Wants=wg-quick@${WG_IF}.service yt-main-route.service

[Service]
Environment=V2NODE_YOUTUBE_SOURCE=${local_ip}
EOF
}

backup_binary(){
  mkdir -p "$STATE_DIR/backups"
  local dst="$STATE_DIR/backups/v2node.$(date +%Y%m%d-%H%M%S)"
  cp -a "$V2NODE_BIN" "$dst"
  ln -sfn "$dst" "$STATE_DIR/backups/latest"
  echo "$dst"
}

restore_binary(){
  local latest="$STATE_DIR/backups/latest"
  [[ -e "$latest" ]] || return 1
  cp -a "$(readlink -f "$latest")" "$V2NODE_BIN"
  chmod 755 "$V2NODE_BIN"
}

cleanup_runtime(){
  local local_ip="${LOCAL_TUNNEL_IP:-}"
  rm -f "$DROPIN_FILE"
  systemctl daemon-reload >/dev/null 2>&1 || true
  systemctl disable --now yt-main-route.service >/dev/null 2>&1 || true
  systemctl disable --now "wg-quick@${WG_IF}" >/dev/null 2>&1 || true
  if [[ -n "$local_ip" ]]; then
    while ip rule del from "$local_ip/32" table "$TABLE_ID" 2>/dev/null; do :; done
  fi
  ip route flush table "$TABLE_ID" 2>/dev/null || true
}

cmd_prepare(){
  need_root; check_v2node; install_deps
  [[ ! -f /etc/yt-exit/state.env ]] || die "VPS này đang cài yt-exit. MAIN và EXIT phải là hai VPS khác nhau."

  if [[ -f "$STATE_FILE" ]]; then warn "yt-main đã prepare."; cmd_info; return 0; fi

  read -rp "EXIT Public IP: " EXIT_PUBLIC_IP
  read -rp "EXIT Public Key: " EXIT_PUBLIC_KEY
  read -rp "EXIT Port [44443]: " EXIT_PORT
  EXIT_PORT="${EXIT_PORT:-44443}"
  read -rp "EXIT tunnel IP [10.88.0.1]: " EXIT_TUNNEL_IP
  EXIT_TUNNEL_IP="${EXIT_TUNNEL_IP:-10.88.0.1}"

  [[ "$EXIT_PUBLIC_IP" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "EXIT Public IP không hợp lệ."
  [[ "$EXIT_PUBLIC_KEY" =~ ^[A-Za-z0-9+/]{42,44}=$ ]] || die "EXIT Public Key không hợp lệ."
  [[ "$EXIT_PORT" =~ ^[0-9]+$ ]] && (( EXIT_PORT >= 1 && EXIT_PORT <= 65535 )) || die "EXIT port không hợp lệ."
  [[ "$EXIT_TUNNEL_IP" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "EXIT tunnel IP không hợp lệ."

  OUT_IF="$(detect_out_if)"
  DEFAULT_ROUTE_BEFORE="$(default_route)"
  WG_MTU="${YT_WG_MTU:-$DEFAULT_MTU}"
  [[ "$WG_MTU" =~ ^[0-9]+$ ]] && (( WG_MTU >= 1280 && WG_MTU <= 1500 )) || die "MTU không hợp lệ (1280-1500)."

  [[ ! -f /etc/yt-exit/state.env ]] || die "VPS này đang cài yt-exit."
  ip link show "$WG_IF" >/dev/null 2>&1 && die "Interface $WG_IF đã tồn tại."
  ip rule show | grep -Eq "lookup ${TABLE_ID}($| )" && die "Routing table $TABLE_ID đang được dùng bởi rule khác."
  ip rule show | grep -Eq "^${RULE_PRIO}:" && die "Rule priority $RULE_PRIO đang được dùng."
  ip route show table "$TABLE_ID" 2>/dev/null | grep -q . && die "Routing table $TABLE_ID không trống."
  [[ -n "$OUT_IF" ]] || die "Không phát hiện default interface."

  download_binary "${1:-}"

  mkdir -p "$STATE_DIR"; chmod 700 "$STATE_DIR"
  local priv pub
  priv="$(wg genkey)"
  pub="$(printf '%s' "$priv" | wg pubkey)"
  printf '%s\n' "$priv" >"$STATE_DIR/private.key"
  printf '%s\n' "$pub" >"$STATE_DIR/public.key"
  chmod 600 "$STATE_DIR/private.key"; chmod 644 "$STATE_DIR/public.key"

  save_state

  ok "MAIN đã prepare. Chưa thay binary V2Node, chưa đổi route."
  echo
  echo "===== MAIN PUBLIC KEY ====="
  echo "$pub"
  echo
  echo "Trên VPS EXIT chạy:"
  echo "  yt-exit add MAIN-01 $pub"
  echo
  echo "Sau đó EXIT sẽ trả MAIN_TUNNEL_IP=x.x.x.x"
  echo "Quay lại MAIN chạy: yt-main activate x.x.x.x"
}

cmd_info(){
  need_root; load_state || die "Chưa prepare."
  echo "===== YT MAIN INFO ====="
  echo "EXIT Public IP : $EXIT_PUBLIC_IP"
  echo "EXIT Public Key: $EXIT_PUBLIC_KEY"
  echo "EXIT Port      : $EXIT_PORT"
  echo "EXIT Tunnel IP : $EXIT_TUNNEL_IP"
  echo "MAIN Public Key: $(cat "$STATE_DIR/public.key")"
  echo "Default IF     : $OUT_IF"
  [[ -n "${LOCAL_TUNNEL_IP:-}" ]] && echo "MAIN Tunnel IP : $LOCAL_TUNNEL_IP"
}

cmd_activate(){
  need_root; load_state || die "Chưa prepare."
  local local_ip="${1:-}"
  [[ -n "$local_ip" ]] || read -rp "MAIN tunnel IP do EXIT cấp: " local_ip
  local_ip="${local_ip%/32}"
  [[ "$local_ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "MAIN tunnel IP không hợp lệ."
  [[ "$(tunnel_prefix "$local_ip")" == "$(tunnel_prefix "$EXIT_TUNNEL_IP")" ]] || die "MAIN và EXIT tunnel IP phải cùng subnet /24."
  check_tunnel_collision "$local_ip"
  LOCAL_TUNNEL_IP="$local_ip"
  echo "LOCAL_TUNNEL_IP='$LOCAL_TUNNEL_IP'" >>"$STATE_FILE"

  local priv before after backup
  priv="$(cat "$STATE_DIR/private.key")"
  before="$(default_route)"

  ip link show "$WG_IF" >/dev/null 2>&1 && die "$WG_IF đã tồn tại."

  make_wg_conf "$priv" "$LOCAL_TUNNEL_IP"
  make_route_files "$LOCAL_TUNNEL_IP"

  systemctl daemon-reload
  systemctl start "wg-quick@${WG_IF}"
  sleep 1

  after="$(default_route)"
  [[ "$after" == "$before" ]] || { cleanup_runtime; die "WireGuard làm thay default route. Đã rollback."; }

  systemctl start yt-main-route.service
  sleep 1

  ip route get 8.8.8.8 from "$LOCAL_TUNNEL_IP" 2>/dev/null | grep -q "dev $WG_IF" || {
    cleanup_runtime; die "Policy route chưa đúng. Đã rollback."
  }

  ping -c 2 -W 2 -I "$WG_IF" "$EXIT_TUNNEL_IP" >/dev/null 2>&1 || {
    cleanup_runtime; die "Không kết nối được EXIT tunnel."
  }

  backup="$(backup_binary)"
  info "Backup V2Node: $backup"

  cp -a "$CUSTOM_BIN" "$V2NODE_BIN"
  chmod 755 "$V2NODE_BIN"
  make_v2node_dropin "$LOCAL_TUNNEL_IP"

  systemctl daemon-reload
  systemctl restart "$V2NODE_SERVICE"
  sleep 4

  if ! systemctl is-active --quiet "$V2NODE_SERVICE"; then
    restore_binary || true
    rm -f "$DROPIN_FILE"
    systemctl daemon-reload
    systemctl restart "$V2NODE_SERVICE" >/dev/null 2>&1 || true
    cleanup_runtime
    die "V2Node custom không chạy. Đã rollback."
  fi

  [[ "$(default_route)" == "$before" ]] || {
    restore_binary || true
    rm -f "$DROPIN_FILE"
    systemctl daemon-reload
    systemctl restart "$V2NODE_SERVICE" >/dev/null 2>&1 || true
    cleanup_runtime
    die "Default route thay đổi sau restart V2Node. Đã rollback."
  }

  systemctl enable "wg-quick@${WG_IF}" yt-main-route.service "$V2NODE_SERVICE" >/dev/null
  ok "YT MAIN đã ACTIVE."
  cmd_test
}

cmd_status(){
  need_root; load_state || die "Chưa prepare."
  echo "===== V2NODE ====="
  systemctl is-enabled "$V2NODE_SERVICE" 2>/dev/null || true
  systemctl is-active "$V2NODE_SERVICE" 2>/dev/null || true
  if [[ -s "$ASSET_DIR/custom.sha256" && -x "$V2NODE_BIN" ]]; then
    current_sha="$(sha256sum "$V2NODE_BIN" | awk '{print $1}')"
    custom_sha="$(cat "$ASSET_DIR/custom.sha256")"
    if [[ "$current_sha" == "$custom_sha" ]]; then
      ok "Binary custom đang được dùng"
    else
      warn "Binary V2Node đã thay đổi (có thể vừa update upstream). Chạy yt-main repair sau khi đảm bảo asset custom mới tương thích."
    fi
  fi
  echo; echo "===== WG ====="
  ip link show "$WG_IF" 2>/dev/null | grep -o "mtu [0-9]*" || true
  systemctl is-enabled "wg-quick@${WG_IF}" 2>/dev/null || true
  systemctl is-active "wg-quick@${WG_IF}" 2>/dev/null || true
  wg show "$WG_IF" 2>/dev/null || true
  echo; echo "===== ROUTE ====="
  systemctl is-enabled yt-main-route.service 2>/dev/null || true
  systemctl is-active yt-main-route.service 2>/dev/null || true
  ip rule show | grep -E "lookup ${TABLE_ID}" || true
  ip route show table "$TABLE_ID" 2>/dev/null || true
  echo; echo "===== DEFAULT ====="; default_route
}

cmd_test(){
  need_root; load_state || die "Chưa prepare."
  local fail=0 current_if
  echo "===== TEST ====="
  systemctl is-active --quiet "$V2NODE_SERVICE" && ok "V2Node active" || { warn "V2Node inactive"; fail=1; }
  systemctl is-active --quiet "wg-quick@${WG_IF}" && ok "WireGuard active" || { warn "WireGuard inactive"; fail=1; }
  systemctl is-active --quiet yt-main-route.service && ok "Route service active" || { warn "Route service inactive"; fail=1; }

  current_if="$(detect_out_if)"
  [[ "$current_if" == "$OUT_IF" ]] && ok "Default interface vẫn là $OUT_IF" || { warn "Default interface đổi thành $current_if"; fail=1; }

  ip route get 1.1.1.1 | grep -q "dev $OUT_IF" && ok "Traffic thường vẫn đi MAIN" || { warn "Traffic thường không đi MAIN"; fail=1; }

  if [[ -n "${LOCAL_TUNNEL_IP:-}" ]]; then
    ip route get 8.8.8.8 from "$LOCAL_TUNNEL_IP" 2>/dev/null | grep -q "dev $WG_IF" && ok "YouTube source đi $WG_IF" || { warn "Policy route YouTube sai"; fail=1; }
    ping -c 2 -W 2 -I "$WG_IF" "$EXIT_TUNNEL_IP" >/dev/null 2>&1 && ok "Tunnel MAIN ↔ EXIT OK" || { warn "Không ping được EXIT tunnel"; fail=1; }
  else
    warn "Chưa activate MAIN tunnel IP."; fail=1
  fi

  if wg show "$WG_IF" latest-handshakes 2>/dev/null | awk '$2 > 0 {ok=1} END{exit !ok}'; then
    ok "WireGuard đã có handshake"
  else
    warn "WireGuard chưa có handshake"
    fail=1
  fi

  echo; wg show "$WG_IF" 2>/dev/null || true
  return "$fail"
}

cmd_watch(){
  need_root; load_state || die "Chưa prepare."
  local sec="${1:-60}"
  [[ -d "/sys/class/net/$WG_IF" ]] || die "$WG_IF chưa active."
  local rx1 tx1 rx2 tx2
  rx1="$(cat "/sys/class/net/$WG_IF/statistics/rx_bytes")"
  tx1="$(cat "/sys/class/net/$WG_IF/statistics/tx_bytes")"
  echo "Mở YouTube trong $sec giây..."
  echo "BEFORE RX=$rx1 TX=$tx1"
  sleep "$sec"
  rx2="$(cat "/sys/class/net/$WG_IF/statistics/rx_bytes")"
  tx2="$(cat "/sys/class/net/$WG_IF/statistics/tx_bytes")"
  echo "AFTER  RX=$rx2 TX=$tx2"
  echo "DELTA  RX=$((rx2-rx1)) TX=$((tx2-tx1))"
}

cmd_repair(){
  need_root; load_state || die "Chưa prepare."
  [[ -n "${LOCAL_TUNNEL_IP:-}" ]] || die "Chưa activate."
  [[ -s "$CUSTOM_BIN" ]] || die "Mất custom binary asset."

  if [[ -s "$ASSET_DIR/custom.sha256" && -x "$V2NODE_BIN" ]]; then
    current_sha="$(sha256sum "$V2NODE_BIN" | awk '{print $1}')"
    custom_sha="$(cat "$ASSET_DIR/custom.sha256")"
    if [[ "$current_sha" != "$custom_sha" && "${YT_FORCE_REPAIR:-0}" != "1" ]]; then
      die "V2Node hiện tại khác custom asset (có thể vừa update upstream). Không tự hạ phiên bản. Hãy build/release Core tương thích rồi dùng 'yt-main update-core'."
    fi
  fi

  backup_binary >/dev/null
  cp -a "$CUSTOM_BIN" "$V2NODE_BIN"
  chmod 755 "$V2NODE_BIN"
  make_v2node_dropin "$LOCAL_TUNNEL_IP"
  make_route_files "$LOCAL_TUNNEL_IP"
  systemctl daemon-reload
  systemctl enable --now "wg-quick@${WG_IF}" yt-main-route.service >/dev/null
  systemctl restart "$V2NODE_SERVICE"
  sleep 3
  cmd_test
}

cmd_rollback(){
  need_root; load_state || die "Chưa prepare."
  restore_binary || die "Không có backup binary."
  rm -f "$DROPIN_FILE"
  systemctl daemon-reload
  systemctl restart "$V2NODE_SERVICE"
  ok "Đã rollback V2Node gốc. Tunnel vẫn giữ nhưng route YouTube trong V2Node đã tắt."
}

cmd_uninstall(){
  need_root; load_state || true
  warn "Đang gỡ yt-main..."
  rm -f "$DROPIN_FILE"
  systemctl daemon-reload >/dev/null 2>&1 || true
  systemctl disable --now yt-main-route.service >/dev/null 2>&1 || true
  systemctl disable --now "wg-quick@${WG_IF}" >/dev/null 2>&1 || true
  if [[ -n "${LOCAL_TUNNEL_IP:-}" ]]; then
    while ip rule del from "$LOCAL_TUNNEL_IP/32" table "$TABLE_ID" 2>/dev/null; do :; done
  fi
  ip route flush table "$TABLE_ID" 2>/dev/null || true
  if [[ -s "$ASSET_DIR/custom.sha256" && -x "$V2NODE_BIN" ]]; then
    current_sha="$(sha256sum "$V2NODE_BIN" | awk '{print $1}')"
    custom_sha="$(cat "$ASSET_DIR/custom.sha256")"
    if [[ "$current_sha" == "$custom_sha" ]]; then
      restore_binary || true
    else
      warn "Giữ nguyên binary V2Node hiện tại vì nó không còn là custom binary (có thể đã update upstream)."
    fi
  else
    restore_binary || true
  fi
  systemctl daemon-reload >/dev/null 2>&1 || true
  systemctl restart "$V2NODE_SERVICE" >/dev/null 2>&1 || true
  rm -f "$WG_CONF" "$ROUTE_SCRIPT" "$ROUTE_SERVICE"
  rm -rf "$STATE_DIR" "$ASSET_DIR"
  systemctl daemon-reload >/dev/null 2>&1 || true
  ok "Đã gỡ yt-main. /etc/v2node/config.json không bị sửa."
}


cmd_version(){
  echo "YT MAIN v${VERSION}"
}

cmd_update(){
  need_root
  local tmp="/tmp/yt-main.sh.$$"
  info "Đang kiểm tra bản lệnh mới..."
  curl -4fsSL --retry 3 --connect-timeout 10 "$SELF_URL" -o "$tmp" || die "Không tải được yt-main.sh từ Git."
  bash -n "$tmp" || { rm -f "$tmp"; die "File mới lỗi cú pháp, không cập nhật."; }
  install -m 755 "$tmp" /usr/local/bin/yt-main
  rm -f "$tmp"
  ok "Đã cập nhật yt-main."
  /usr/local/bin/yt-main version
}

cmd_update_core(){
  need_root
  load_state || die "Chưa prepare yt-main."
  check_v2node

  local url="${YT_BINARY_URL:-$DEFAULT_BINARY_URL}"
  local sha_url="${YT_SHA_URL:-$DEFAULT_SHA_URL}"
  local gz="/tmp/v2node-youtube-final.gz.$$"
  local shaf="/tmp/v2node-youtube-final.gz.sha256.$$"
  local newbin="/tmp/v2node-youtube-final.$$"
  local backup expected actual

  info "Tải YouTube Core mới..."
  curl -4fL --retry 3 --connect-timeout 10 "$url" -o "$gz" || die "Không tải được Core."
  curl -4fsSL --retry 3 --connect-timeout 10 "$sha_url" -o "$shaf" || { rm -f "$gz"; die "Không tải được checksum Core."; }

  expected="$(awk 'NR==1{print $1}' "$shaf")"
  actual="$(sha256sum "$gz" | awk '{print $1}')"
  [[ -n "$expected" && "$expected" == "$actual" ]] || { rm -f "$gz" "$shaf"; die "SHA256 Core không khớp."; }

  gzip -dc "$gz" >"$newbin"
  chmod 755 "$newbin"
  "$newbin" version >/dev/null 2>&1 || { rm -f "$gz" "$shaf" "$newbin"; die "Core mới không chạy được."; }

  backup="$(backup_binary)"
  info "Backup V2Node hiện tại: $backup"

  cp -a "$newbin" "$CUSTOM_BIN"
  chmod 755 "$CUSTOM_BIN"
  sha256sum "$CUSTOM_BIN" | awk '{print $1}' >"$ASSET_DIR/custom.sha256"

  cp -a "$CUSTOM_BIN" "$V2NODE_BIN"
  chmod 755 "$V2NODE_BIN"

  systemctl restart "$V2NODE_SERVICE"
  sleep 4

  if ! systemctl is-active --quiet "$V2NODE_SERVICE"; then
    restore_binary || true
    systemctl restart "$V2NODE_SERVICE" >/dev/null 2>&1 || true
    rm -f "$gz" "$shaf" "$newbin"
    die "Core mới làm V2Node lỗi. Đã rollback."
  fi

  if [[ -n "${LOCAL_TUNNEL_IP:-}" ]]; then
    if ! ip route get 8.8.8.8 from "$LOCAL_TUNNEL_IP" 2>/dev/null | grep -q "dev $WG_IF"; then
      restore_binary || true
      systemctl restart "$V2NODE_SERVICE" >/dev/null 2>&1 || true
      rm -f "$gz" "$shaf" "$newbin"
      die "Policy route không còn đúng sau update Core. Đã rollback."
    fi
  fi

  rm -f "$gz" "$shaf" "$newbin"
  ok "Đã cập nhật YouTube Core."
}

menu(){
  while true; do
    clear 2>/dev/null || true
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "       YT MAIN v${VERSION}"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    printf "V2Node : "
    systemctl is-active --quiet "$V2NODE_SERVICE" 2>/dev/null && echo "ACTIVE" || echo "OFF"
    printf "WG     : "
    systemctl is-active --quiet "wg-quick@${WG_IF}" 2>/dev/null && echo "ACTIVE" || echo "OFF"
    echo
    echo "1) Cài/Kết nối EXIT"
    echo "2) Trạng thái"
    echo "3) Kiểm tra"
    echo "4) Test YouTube"
    echo "5) Sửa chữa"
    echo "6) Cập nhật lệnh"
    echo "7) Cập nhật Core"
    echo "8) Rollback"
    echo "9) Gỡ"
    echo "0) Thoát"
    echo
    read -rp "Chọn: " c
    case "$c" in
      1)
        if systemctl is-active --quiet "wg-quick@${WG_IF}" 2>/dev/null; then
          ok "YT MAIN đã được kích hoạt."
          cmd_info || true
        elif [[ -f "$STATE_FILE" ]]; then
          read -rp "MAIN tunnel IP do EXIT cấp: " tip
          cmd_activate "$tip" || true
        else
          cmd_prepare || true
        fi
        ;;
      2) cmd_status || true ;;
      3) cmd_test || true ;;
      4) cmd_watch 60 || true ;;
      5) cmd_repair || true ;;
      6) cmd_update || true ;;
      7)
        read -rp "Cập nhật YouTube Core? [y/N]: " y
        [[ "$y" =~ ^[Yy]$ ]] && cmd_update_core || true
        ;;
      8)
        read -rp "Rollback V2Node? [y/N]: " y
        [[ "$y" =~ ^[Yy]$ ]] && cmd_rollback || true
        ;;
      9)
        read -rp "Gỡ YT MAIN? [y/N]: " y
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
YT MAIN - VPS chạy V2Node/VLESS cho khách

  yt-main prepare [LOCAL_BINARY_FILE]
  yt-main info
  yt-main activate <MAIN_TUNNEL_IP>
  yt-main status
  yt-main test
  yt-main watch [SECONDS]
  yt-main repair
  yt-main update
  yt-main update-core
  yt-main version
  yt-main rollback
  yt-main uninstall
EOF
}

case "${1:-}" in
  "") menu ;;
  prepare) shift; cmd_prepare "$@" ;;
  info) shift; cmd_info "$@" ;;
  activate) shift; cmd_activate "$@" ;;
  status) shift; cmd_status "$@" ;;
  test) shift; cmd_test "$@" ;;
  watch) shift; cmd_watch "$@" ;;
  repair) shift; cmd_repair "$@" ;;
  update) shift; cmd_update "$@" ;;
  update-core) shift; cmd_update_core "$@" ;;
  version) shift; cmd_version "$@" ;;
  rollback) shift; cmd_rollback "$@" ;;
  uninstall) shift; cmd_uninstall "$@" ;;
  *) usage ;;
esac
