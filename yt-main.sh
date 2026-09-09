#!/usr/bin/env bash
set -Eeuo pipefail
VERSION="7.7.0-base"
IF=ytwg0; STATE=/etc/yt-v7; ROLE_FILE=$STATE/role; CONF=/etc/wireguard/$IF.conf
die(){ echo "[ERROR] $*" >&2; exit 1; }; ok(){ echo "[OK] $*"; }; warn(){ echo "[WARN] $*"; }

apt_busy() {
  command -v fuser >/dev/null 2>&1 || return 1
  fuser /var/lib/dpkg/lock-frontend /var/lib/dpkg/lock /var/cache/apt/archives/lock >/dev/null 2>&1
}
wait_apt_short() {
  local n=0
  while apt_busy && (( n < 20 )); do
    ((n++))
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
  apt-get install -y --no-install-recommends "${pkgs[@]}"
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
reload_or_start(){
  if systemctl is-active --quiet wg-quick@$IF; then
    systemctl reload wg-quick@$IF
  else
    systemctl enable --now wg-quick@$IF
  fi
}
install_main(){
  [[ $EUID -eq 0 ]] || die "Chạy root"; ensure_deps; role_guard; collision_guard
  command -v python3 >/dev/null || install_missing python3
  local eip epub port mip before after priv bak="" first_install=0
  [[ -f "$ROLE_FILE" ]] || first_install=1
  read -rp "EXIT Public IP: " eip; read -rp "EXIT Public Key: " epub
  read -rp "EXIT Port [44443]: " port; port=${port:-44443}
  read -rp "MAIN tunnel IP [10.88.0.2]: " mip; mip=${mip:-10.88.0.2}
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

  if ! reload_or_start; then
    if [[ -n "$bak" ]]; then
      mv -f "$bak" "$CONF"
      systemctl restart "wg-quick@$IF" >/dev/null 2>&1 || true
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
      systemctl restart "wg-quick@$IF" >/dev/null 2>&1 || true
    else
      systemctl disable --now "wg-quick@$IF" >/dev/null 2>&1 || true
      rm -f "$CONF"
    fi
    [[ "$first_install" -eq 0 ]] || rm -f "$ROLE_FILE"
    die "Default route đổi; đã rollback MAIN."
  fi

  [[ -z "$bak" ]] || rm -f "$bak"
  ok "MAIN BASE active; V2Node untouched."; echo "MAIN Public Key: $(cat "$STATE/main.pub")"
}
status(){ echo "V2Node: $(systemctl is-active v2node 2>/dev/null||true)"; echo "WG: $(systemctl is-active wg-quick@$IF 2>/dev/null||true)"; default_route; wg show "$IF" 2>/dev/null||true; }
menu(){ while true; do echo "YT V7 MAIN $VERSION"; echo "1) Cài/Cập nhật MAIN"; echo "2) Trạng thái"; echo "0) Thoát"; read -rp "Chọn: " x; case $x in 1) install_main;;2) status;;0) exit;;esac; done; }
case "${1:-menu}" in install) install_main;;status) status;;*) menu;;esac
