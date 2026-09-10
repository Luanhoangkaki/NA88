#!/usr/bin/env bash
set -Eeuo pipefail
VERSION="7.7.2-base"
IF=ytwg0; STATE=/etc/yt-v7; ROLE_FILE=$STATE/role; PEERS=$STATE/peers
CONF=/etc/wireguard/$IF.conf; SYSCTL=/etc/sysctl.d/99-yt-v7-forward.conf; BASE_CONF=$STATE/exit-base.env
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
 command -v iptables >/dev/null || p+=(iptables)
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
  [[ -z "$r" || "$r" == EXIT ]] || die "VPS đã là MAIN."
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
load_base(){ [[ -s "$BASE_CONF" ]] || die "EXIT chưa cài"; source "$BASE_CONF"; }
write_conf(){
 load_base; local priv; priv=$(cat "$STATE/exit.key")
 atomic_write "$CONF" 600 <<EOF
[Interface]
Address = ${EXIT_IP}/24
ListenPort = ${PORT}
PrivateKey = ${priv}
Table = off
PostUp = iptables -C FORWARD -i %i -o ${OUT_IF} -j ACCEPT 2>/dev/null || iptables -A FORWARD -i %i -o ${OUT_IF} -j ACCEPT
PostUp = iptables -C FORWARD -i ${OUT_IF} -o %i -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || iptables -A FORWARD -i ${OUT_IF} -o %i -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
PostUp = iptables -t nat -C POSTROUTING -s ${EXIT_IP%.*}.0/24 -o ${OUT_IF} -j MASQUERADE 2>/dev/null || iptables -t nat -A POSTROUTING -s ${EXIT_IP%.*}.0/24 -o ${OUT_IF} -j MASQUERADE
PostDown = iptables -D FORWARD -i %i -o ${OUT_IF} -j ACCEPT 2>/dev/null || true
PostDown = iptables -D FORWARD -i ${OUT_IF} -o %i -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || true
PostDown = iptables -t nat -D POSTROUTING -s ${EXIT_IP%.*}.0/24 -o ${OUT_IF} -j MASQUERADE 2>/dev/null || true
EOF
 if compgen -G "$PEERS/*.conf" >/dev/null; then for f in "$PEERS"/*.conf; do printf '\n' >>"$CONF"; cat "$f" >>"$CONF"; done; fi
}
peer_reload_or_start(){
 if systemctl is-active --quiet "wg-quick@$IF"; then
   systemctl reload "wg-quick@$IF"
 else
   systemctl enable --now "wg-quick@$IF"
 fi
}
full_apply(){
 if systemctl is-active --quiet "wg-quick@$IF"; then
   systemctl restart "wg-quick@$IF"
 else
   systemctl enable --now "wg-quick@$IF"
 fi
}

restore_exit_state(){
  local oldf_restore="$1" conf_bak="${2:-}" base_bak="${3:-}" first_install="${4:-0}"

  if [[ -n "$conf_bak" && -f "$conf_bak" ]]; then
    mv -f "$conf_bak" "$CONF"
  else
    rm -f "$CONF"
  fi

  if [[ -n "$base_bak" && -f "$base_bak" ]]; then
    mv -f "$base_bak" "$BASE_CONF"
  else
    rm -f "$BASE_CONF"
  fi

  [[ "$first_install" -eq 0 ]] || {
    rm -f "$ROLE_FILE" "$SYSCTL"
  }

  sysctl -w "net.ipv4.ip_forward=$oldf_restore" >/dev/null 2>&1 || true
}

install_exit(){
  [[ $EUID -eq 0 ]] || die "Chạy root"
  ensure_deps
  role_guard
  collision_guard
  command -v python3 >/dev/null || install_missing python3

  local port eip oif before after oldf
  local conf_bak="" base_bak="" first_install=0
  [[ -f "$ROLE_FILE" ]] || first_install=1

  read -rp "Port [44443]: " port
  port=${port:-44443}
  read -rp "EXIT tunnel IP [10.88.0.1]: " eip
  eip=${eip:-10.88.0.1}

  valid_port "$port" || die "Port sai"
  valid_ipv4 "$eip" || die "IP sai"

  oif=$(ip route show default | awk 'NR==1{for(i=1;i<=NF;i++)if($i=="dev"){print $(i+1);exit}}')
  [[ -n "$oif" ]] || die "Không có OUT IF"

  mkdir -p "$STATE" "$PEERS" /etc/wireguard
  chmod 700 "$STATE" "$PEERS" /etc/wireguard

  [[ -s "$STATE/exit.key" ]] || (umask 077; wg genkey >"$STATE/exit.key")
  wg pubkey <"$STATE/exit.key" >"$STATE/exit.pub"

  oldf=$(sysctl -n net.ipv4.ip_forward 2>/dev/null || echo 0)

  if [[ -f "$CONF" ]]; then
    conf_bak="$CONF.bak.$(date +%s)"
    cp -a "$CONF" "$conf_bak"
  fi

  # Keep the ORIGINAL forwarding state from the first successful install.
  if [[ -s "$BASE_CONF" ]]; then
    base_bak="$BASE_CONF.bak.$(date +%s)"
    cp -a "$BASE_CONF" "$base_bak"
    # shellcheck disable=SC1090
    source "$BASE_CONF"
    oldf="${IP_FORWARD_BEFORE:-$oldf}"
  fi

  atomic_write "$BASE_CONF" 600 <<EOF
PORT='$port'
EXIT_IP='$eip'
OUT_IF='$oif'
IP_FORWARD_BEFORE='$oldf'
EOF

  [[ "$first_install" -eq 0 ]] || printf 'EXIT\n' >"$ROLE_FILE"
  write_conf

  printf 'net.ipv4.ip_forward=1\n' >"$SYSCTL"
  sysctl -w net.ipv4.ip_forward=1 >/dev/null

  before=$(default_route)

  if ! full_apply; then
    systemctl disable --now "wg-quick@$IF" >/dev/null 2>&1 || true

    if [[ -n "$conf_bak" && -f "$conf_bak" ]]; then
      mv -f "$conf_bak" "$CONF"
    else
      rm -f "$CONF"
    fi

    if [[ -n "$base_bak" && -f "$base_bak" ]]; then
      mv -f "$base_bak" "$BASE_CONF"
    else
      rm -f "$BASE_CONF"
    fi

    if [[ "$first_install" -eq 1 ]]; then
      rm -f "$ROLE_FILE" "$SYSCTL"
    fi

    sysctl -w "net.ipv4.ip_forward=$oldf" >/dev/null 2>&1 || true

    if [[ "$first_install" -eq 0 && -f "$CONF" ]]; then
      systemctl restart "wg-quick@$IF" >/dev/null 2>&1 || true
    fi

    die "Apply EXIT lỗi; đã rollback."
  fi

  after=$(default_route)
  if [[ "$before" != "$after" ]]; then
    systemctl disable --now "wg-quick@$IF" >/dev/null 2>&1 || true

    if [[ -n "$conf_bak" && -f "$conf_bak" ]]; then
      mv -f "$conf_bak" "$CONF"
    else
      rm -f "$CONF"
    fi

    if [[ -n "$base_bak" && -f "$base_bak" ]]; then
      mv -f "$base_bak" "$BASE_CONF"
    else
      rm -f "$BASE_CONF"
    fi

    if [[ "$first_install" -eq 1 ]]; then
      rm -f "$ROLE_FILE" "$SYSCTL"
    fi

    sysctl -w "net.ipv4.ip_forward=$oldf" >/dev/null 2>&1 || true

    if [[ "$first_install" -eq 0 && -f "$CONF" ]]; then
      systemctl restart "wg-quick@$IF" >/dev/null 2>&1 || true
    fi

    die "Default route đổi; đã rollback EXIT."
  fi

  [[ -z "$conf_bak" ]] || rm -f "$conf_bak"
  [[ -z "$base_bak" ]] || rm -f "$base_bak"

  ok "EXIT BASE active"
  echo "EXIT Public Key: $(cat "$STATE/exit.pub")"
  echo "UDP Port: $port"
  echo "[INFO] Script không tự sửa firewall INPUT. Nếu handshake lỗi, kiểm tra UDP $port."
}

add_main(){
  [[ $EUID -eq 0 ]] || die "Chạy root"
  ensure_deps
  role_guard
  load_base
  command -v python3 >/dev/null || install_missing python3

  local n pub mip f bak=""
  read -rp "Tên MAIN [MAIN-01]: " n
  n=${n:-MAIN-01}
  n=$(tr -cd A-Za-z0-9_.- <<<"$n")
  [[ -n "$n" ]] || die "Tên sai"

  read -rp "MAIN Public Key: " pub
  pub=$(printf '%s' "$pub" | tr -d '[:space:]')
  echo "[CHECK] MAIN Public Key: $pub"
  read -rp "MAIN tunnel IP [10.88.0.2]: " mip
  mip=${mip:-10.88.0.2}

  valid_key "$pub" || die "Key sai"
  valid_ipv4 "$mip" || die "IP sai"
  [[ "$mip" != "$EXIT_IP" ]] || die "IP trùng EXIT"

  f="$PEERS/$n.conf"
  if [[ -f "$f" ]]; then
    bak="$f.bak.$(date +%s)"
    cp -a "$f" "$bak"
  fi

  atomic_write "$f" 600 <<EOF
[Peer]
PublicKey = $pub
AllowedIPs = ${mip}/32
EOF

  write_conf

  if ! peer_reload_or_start; then
    if [[ -n "$bak" && -f "$bak" ]]; then
      mv -f "$bak" "$f"
    else
      rm -f "$f"
    fi
    write_conf
    peer_reload_or_start >/dev/null 2>&1 || true
    die "Peer apply lỗi; đã rollback."
  fi

  local applied_pub
  applied_pub=$(wg show "$IF" peers 2>/dev/null | grep -Fx "$pub" || true)
  if [[ "$applied_pub" != "$pub" ]]; then
    if [[ -n "$bak" && -f "$bak" ]]; then
      mv -f "$bak" "$f"
    else
      rm -f "$f"
    fi
    write_conf
    full_apply >/dev/null 2>&1 || true
    die "Peer key runtime không khớp; đã rollback."
  fi

  [[ -z "$bak" ]] || rm -f "$bak"
  ok "Đã thêm MAIN"
  echo "[CHECK] MAIN peer runtime: $applied_pub"

  echo "[CHECK] Chờ WireGuard handshake từ MAIN (tối đa 35 giây)..."
  local hs=0 i latest
  for i in {1..7}; do
    latest=$(wg show "$IF" latest-handshakes 2>/dev/null | awk -v k="$pub" '$1==k {print $2}')
    if [[ "$latest" =~ ^[0-9]+$ ]] && (( latest > 0 )); then
      hs=1
      break
    fi
    sleep 5
  done

  if (( hs == 1 )); then
    echo "[OK] HANDSHAKE PASS - MAIN đã xác thực với EXIT."
  else
    echo "[WARN] HANDSHAKE FAIL - chưa thấy MAIN handshake trong 35 giây."
    echo "[WARN] Peer vẫn được giữ nguyên vì MAIN có thể chưa online/chưa bật ytwg0."
    echo "[WARN] Hãy kiểm tra MAIN Public Key, endpoint UDP ${PORT}, và chạy trạng thái ở cả hai VPS."
  fi
}

status(){ echo "WG: $(systemctl is-active wg-quick@$IF 2>/dev/null||true)"; echo "ip_forward=$(sysctl -n net.ipv4.ip_forward 2>/dev/null||true)"; default_route; wg show "$IF" 2>/dev/null||true; }
uninstall_exit(){
 [[ $EUID -eq 0 ]]||die "Chạy root"; role_guard; local old=1
 if [[ -s "$BASE_CONF" ]]; then source "$BASE_CONF"; old=${IP_FORWARD_BEFORE:-1}; fi
 systemctl disable --now wg-quick@$IF >/dev/null 2>&1||true
 rm -f "$CONF" "$SYSCTL"
 # Conservative ownership: never force forwarding OFF. Only restore 1 if it was already 1.
 [[ "$old" == 1 ]]&&sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1||true
 rm -rf "$STATE"; ok "Đã gỡ EXIT. Không ép ip_forward về 0."
}
menu(){ while true; do echo "YT V7 EXIT $VERSION"; echo "1) Cài/Cập nhật EXIT"; echo "2) Thêm MAIN"; echo "3) Trạng thái"; echo "4) Gỡ"; echo "0) Thoát"; read -rp "Chọn: " x; case $x in 1) install_exit;;2)add_main;;3)status;;4)uninstall_exit;;0)exit;;esac; done; }
case "${1:-menu}" in install)install_exit;;add-main)add_main;;status)status;;uninstall)uninstall_exit;;*)menu;;esac
