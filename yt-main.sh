#!/usr/bin/env bash
set -Eeuo pipefail
VERSION="7.8.0-rc2"
IF=ytwg0; STATE=/etc/yt-v7; ROLE_FILE=$STATE/role; CONF=/etc/wireguard/$IF.conf
die(){ echo "[ERROR] $*" >&2; exit 1; }; ok(){ echo "[OK] $*"; }; warn(){ echo "[WARN] $*"; }

apt_busy() {
  command -v fuser >/dev/null 2>&1 || return 1
  fuser /var/lib/dpkg/lock-frontend /var/lib/dpkg/lock /var/cache/apt/archives/lock >/dev/null 2>&1
}
wait_apt_short() {
  local n=0
  while apt_busy && (( n < 20 )); do
    ((++n))
    echo "[WAIT] APT đang bận... ${n}/20"
    sleep 3
  done
  ! apt_busy
}
install_missing() {
  local pkgs=("$@")
  ((${#pkgs[@]})) || return 0
  command -v apt-get >/dev/null 2>&1 || die "Thiếu dependency và hệ thống không có apt-get."
  wait_apt_short || die "APT đang bận. V7 không kill apt/dpkg và không chờ lâu. Hãy chạy lại sau."
  export DEBIAN_FRONTEND=noninteractive
  apt-get install -y --no-install-recommends "${pkgs[@]}" || die "Cài dependency thất bại. Nếu APT đang bận, hãy chạy lại sau."
}
atomic_write() {
  local dst="$1" mode="$2" tmp
  tmp="$(mktemp "${dst}.XXXXXX")"
  cat >"$tmp"
  chmod "$mode" "$tmp"
  mv -f "$tmp" "$dst"
}

ensure_deps(){
  local p=()
  command -v ip >/dev/null || p+=(iproute2)
  command -v wg >/dev/null || p+=(wireguard-tools)
  command -v wg-quick >/dev/null || p+=(wireguard-tools)
  command -v systemctl >/dev/null || die "systemd/systemctl không có."
  install_missing "${p[@]}"
}
valid_port(){ [[ "$1" =~ ^[0-9]+$ ]] && ((10#$1>=1 && 10#$1<=65535)); }
valid_ipv4(){ python3 - "$1" <<'PY' >/dev/null 2>&1
import ipaddress,sys
ipaddress.IPv4Address(sys.argv[1])
PY
}
valid_key(){ [[ "$1" =~ ^[A-Za-z0-9+/]{43}=$ ]]; }

load_existing_main_defaults(){
  OLD_EIP=""; OLD_EPUB=""; OLD_PORT=""; OLD_MIP=""
  [[ -f "$CONF" ]] || return 0

  local addr endpoint
  addr=$(awk -F'=' '/^[[:space:]]*Address[[:space:]]*=/{gsub(/[[:space:]]/,"",$2); print $2; exit}' "$CONF")
  OLD_MIP="${addr%%/*}"

  OLD_EPUB=$(awk -F'=' '
    /^\[Peer\]/{peer=1; next}
    peer && /^[[:space:]]*PublicKey[[:space:]]*=/{sub(/^[^=]*=[[:space:]]*/,""); gsub(/[[:space:]]/,""); print; exit}
  ' "$CONF")

  endpoint=$(awk '
    /^\[Peer\]/{peer=1; next}
    peer && /^[[:space:]]*Endpoint[[:space:]]*=/{sub(/^[^=]*=[[:space:]]*/,""); gsub(/[[:space:]]/,""); print; exit}
  ' "$CONF")

  # V7 MAIN currently supports IPv4 EXIT endpoints. Split only the final :port.
  if [[ "$endpoint" =~ ^([0-9]{1,3}(\.[0-9]{1,3}){3}):([0-9]+)$ ]]; then
    OLD_EIP="${BASH_REMATCH[1]}"
    OLD_PORT="${BASH_REMATCH[3]}"
  fi

  valid_ipv4 "${OLD_EIP:-}" || OLD_EIP=""
  valid_ipv4 "${OLD_MIP:-}" || OLD_MIP=""
  valid_port "${OLD_PORT:-}" || OLD_PORT=""
  valid_key "${OLD_EPUB:-}" || OLD_EPUB=""
}

prompt_with_default(){
  local __var="$1" label="$2" def="${3:-}" value
  if [[ -n "$def" ]]; then
    read -rp "$label [$def]: " value
    value=${value:-$def}
  else
    read -rp "$label: " value
  fi
  printf -v "$__var" '%s' "$value"
}
default_route(){ ip -4 route show default | head -1; }
role_guard(){
  local r
  r=$(cat "$ROLE_FILE" 2>/dev/null || true)
  [[ -z "$r" || "$r" == MAIN ]] || die "VPS đã là EXIT."
  return 0
}
collision_guard(){
  [[ -f "$ROLE_FILE" ]] && return 0
  [[ ! -e "$CONF" ]] || die "$CONF đã tồn tại."
  if ip link show "$IF" >/dev/null 2>&1; then
    die "$IF đã tồn tại."
  fi
  return 0
}
apply_main(){
  if systemctl is-active --quiet "wg-quick@$IF"; then
    systemctl restart "wg-quick@$IF"
  else
    systemctl enable --now "wg-quick@$IF"
  fi
}

restore_main_service_state(){
  local was_enabled="$1" was_active="$2"

  if [[ "$was_enabled" == "enabled" ]]; then
    systemctl enable "wg-quick@$IF" >/dev/null 2>&1 || true
  else
    systemctl disable "wg-quick@$IF" >/dev/null 2>&1 || true
  fi

  if [[ "$was_active" == "active" && -f "$CONF" ]]; then
    systemctl restart "wg-quick@$IF" >/dev/null 2>&1 || true
  else
    systemctl stop "wg-quick@$IF" >/dev/null 2>&1 || true
  fi
}
install_main(){
  [[ $EUID -eq 0 ]] || die "Chạy root"
  local wg_was_enabled wg_was_active
  wg_was_enabled=$(systemctl is-enabled "wg-quick@$IF" 2>/dev/null || true)
  wg_was_active=$(systemctl is-active "wg-quick@$IF" 2>/dev/null || true)
  ensure_deps; role_guard; collision_guard
  command -v python3 >/dev/null || install_missing python3
  local eip epub port mip before after priv bak="" first_install=0
  local OLD_EIP="" OLD_EPUB="" OLD_PORT="" OLD_MIP=""
  [[ -f "$ROLE_FILE" ]] || first_install=1

  load_existing_main_defaults

  if [[ "$first_install" -eq 0 && -n "$OLD_EIP" && -n "$OLD_EPUB" && -n "$OLD_PORT" && -n "$OLD_MIP" ]]; then
    echo "[INFO] Đã đọc cấu hình MAIN hiện tại. Nhấn Enter để giữ nguyên."
  fi

  prompt_with_default eip  "EXIT Public IP"  "$OLD_EIP"
  prompt_with_default epub "EXIT Public Key" "$OLD_EPUB"
  epub=$(printf '%s' "$epub" | tr -d '[:space:]')
  echo "[CHECK] EXIT Public Key: $epub"
  prompt_with_default port "EXIT Port" "${OLD_PORT:-44443}"
  prompt_with_default mip  "MAIN tunnel IP" "${OLD_MIP:-10.88.0.2}"

  valid_ipv4 "$eip" || die "EXIT IP sai"; valid_ipv4 "$mip" || die "MAIN IP sai"
  valid_port "$port" || die "Port sai"; valid_key "$epub" || die "Public Key sai"
  mkdir -p "$STATE" /etc/wireguard; chmod 700 "$STATE" /etc/wireguard
  [[ -s "$STATE/main.key" ]] || (umask 077; wg genkey >"$STATE/main.key")
  wg pubkey <"$STATE/main.key" >"$STATE/main.pub"; priv=$(cat "$STATE/main.key")
  [[ -f "$CONF" ]] && { bak="$CONF.bak.$(date +%s)"; cp -a "$CONF" "$bak"; }
  before=$(default_route)
  atomic_write "$CONF" 600 <<EOF
[Interface]
Address = ${mip}/24
PrivateKey = ${priv}
Table = off

[Peer]
PublicKey = ${epub}
Endpoint = ${eip}:${port}
AllowedIPs = 0.0.0.0/0
PersistentKeepalive = 25
EOF
  [[ "$first_install" -eq 0 ]] || printf 'MAIN\n' >"$ROLE_FILE"

  if ! apply_main; then
    if [[ -n "$bak" ]]; then
      mv -f "$bak" "$CONF"
      restore_main_service_state "$wg_was_enabled" "$wg_was_active"
    else
      systemctl disable --now "wg-quick@$IF" >/dev/null 2>&1 || true
      rm -f "$CONF"
    fi
    [[ "$first_install" -eq 0 ]] || rm -f "$ROLE_FILE"
    die "Apply MAIN lỗi; đã rollback."
  fi

  after=$(default_route)
  if [[ "$before" != "$after" ]]; then
    if [[ -n "$bak" ]]; then
      mv -f "$bak" "$CONF"
      restore_main_service_state "$wg_was_enabled" "$wg_was_active"
    else
      systemctl disable --now "wg-quick@$IF" >/dev/null 2>&1 || true
      rm -f "$CONF"
    fi
    [[ "$first_install" -eq 0 ]] || rm -f "$ROLE_FILE"
    die "Default route đổi; đã rollback MAIN."
  fi

  [[ -z "$bak" ]] || rm -f "$bak"

  systemctl enable "wg-quick@$IF" >/dev/null 2>&1 || die "Không thể enable wg-quick@$IF"
  if ! systemctl is-active --quiet "wg-quick@$IF"; then
    systemctl start "wg-quick@$IF" >/dev/null 2>&1 || die "Không thể start wg-quick@$IF"
  fi
  systemctl is-enabled --quiet "wg-quick@$IF" || die "wg-quick@$IF chưa enabled sau apply."
  systemctl is-active --quiet "wg-quick@$IF" || die "wg-quick@$IF chưa active sau apply."

  ok "MAIN BASE active; V2Node untouched."
  echo "MAIN Public Key: $(cat "$STATE/main.pub")"
  echo "[NEXT] Hãy copy trực tiếp dòng MAIN Public Key này sang EXIT; không gõ lại từ ảnh."

  echo "[CHECK] Chờ WireGuard handshake với EXIT (tối đa 15 giây)..."
  local hs=0 i latest now age
  for i in {1..3}; do
    latest=$(wg show "$IF" latest-handshakes 2>/dev/null | awk -v k="$epub" '$1==k {print $2}')
    now=$(date +%s)
    if [[ "$latest" =~ ^[0-9]+$ ]] && (( latest > 0 )); then
      age=$((now-latest))
      if (( age >= 0 && age <= 30 )); then
        hs=1
        break
      fi
    fi
    sleep 5
  done
  if (( hs == 1 )); then
    echo "[OK] HANDSHAKE PASS - MAIN đã xác thực với EXIT."
  else
    echo "[INFO] Chưa có handshake. Nếu EXIT chưa thêm MAIN Public Key ở trên thì đây là bình thường."
  fi
}
status(){ echo "V2Node: $(systemctl is-active v2node 2>/dev/null||true)"; echo "WG: $(systemctl is-active wg-quick@$IF 2>/dev/null||true)"; default_route; wg show "$IF" 2>/dev/null||true; }

uninstall_main(){
  [[ $EUID -eq 0 ]] || die "Chạy root"
  role_guard
  systemctl disable --now "wg-quick@$IF" >/dev/null 2>&1 || true
  rm -f "$CONF" "$STATE/main.key" "$STATE/main.pub" "$ROLE_FILE"
  rmdir "$STATE" 2>/dev/null || true
  ok "Đã gỡ YT MAIN. Không đụng V2Node."
}
menu(){ while true; do echo "YT V7 MAIN $VERSION"; echo "1) Cài/Cập nhật MAIN"; echo "2) Trạng thái"; echo "3) Gỡ MAIN"; echo "0) Thoát"; read -rp "Chọn: " x; case $x in 1) install_main;;2) status;;3) uninstall_main;;0) exit;;esac; done; }
case "${1:-menu}" in install) install_main;;status) status;;uninstall) uninstall_main;;*) menu;;esac
