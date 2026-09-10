#!/usr/bin/env bash
set -Eeuo pipefail
VERSION="7.8.0-rc2"
IF=ytwg0; STATE=/etc/yt-v7; ROLE_FILE=$STATE/role; PEERS=$STATE/peers; TXN_DIR=$STATE/txn-exit
CONF=/etc/wireguard/$IF.conf; SYSCTL=/etc/sysctl.d/99-yt-v7-forward.conf; BASE_CONF=$STATE/exit-base.env
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

sync_peer_state_from_runtime(){
  # Only needed when an EXIT is already active. Preserve the working runtime
  # peer mapping before write_conf rebuilds the persistent config.
  systemctl is-active --quiet "wg-quick@$IF" || return 0

  local runtime_count state_count=0 pf state_pub state_ip runtime_pub
  runtime_count=$(wg show "$IF" peers 2>/dev/null | sed '/^[[:space:]]*$/d' | wc -l)

  if compgen -G "$PEERS/*.conf" >/dev/null; then
    for pf in "$PEERS"/*.conf; do
      ((++state_count))
      state_pub=$(awk -F' *= *' '$1=="PublicKey"{print $2; exit}' "$pf" 2>/dev/null || true)
      state_ip=$(awk -F' *= *' '$1=="AllowedIPs"{sub(/\/32$/, "", $2); print $2; exit}' "$pf" 2>/dev/null || true)

      [[ -n "$state_pub" && -n "$state_ip" ]] || die "Peer state lỗi: $pf"

      runtime_pub=$(wg show "$IF" allowed-ips 2>/dev/null | awk -v ip="${state_ip}/32" '
        $2==ip {print $1}
      ')

      [[ -n "$runtime_pub" ]] || die "Peer state/runtime lệch tại $state_ip. Dùng mục Thêm/Cập nhật MAIN trước khi update EXIT."

      if [[ "$runtime_pub" != "$state_pub" ]]; then
        sed -i "s|^PublicKey *=.*|PublicKey = ${runtime_pub}|" "$pf"
        echo "[SYNC] Đã đồng bộ peer $(basename "$pf" .conf) theo runtime: $runtime_pub"
      fi
    done
  fi

  [[ "$runtime_count" -eq "$state_count" ]] || die "Số peer runtime ($runtime_count) khác peer state ($state_count). Dừng update để tránh mất peer."
}

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
 systemctl enable "wg-quick@$IF" >/dev/null 2>&1 || return 1
 systemctl is-active --quiet "wg-quick@$IF"
}
full_apply(){
 if systemctl is-active --quiet "wg-quick@$IF"; then
   systemctl restart "wg-quick@$IF"
 else
   systemctl enable --now "wg-quick@$IF"
 fi
}

restore_exit_service_state(){
  local was_enabled="$1" was_active="$2"
  if [[ "$was_enabled" == "enabled" ]]; then
    systemctl enable "wg-quick@$IF" >/dev/null 2>&1 || true
  else
    systemctl disable "wg-quick@$IF" >/dev/null 2>&1 || true
  fi
  if [[ "$was_active" == "active" && -f "$CONF" ]]; then
    systemctl restart "wg-quick@$IF" >/dev/null 2>&1 || true
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

validate_all_peer_ips_in_subnet(){
  local exit_ip="$1" pf peer_ip prefix
  prefix="${exit_ip%.*}."
  if compgen -G "$PEERS/*.conf" >/dev/null; then
    for pf in "$PEERS"/*.conf; do
      peer_ip=$(awk -F' *= *' '$1=="AllowedIPs"{sub(/\/32$/, "", $2); print $2; exit}' "$pf" 2>/dev/null || true)
      valid_ipv4 "$peer_ip" || die "Peer IP không hợp lệ trong $pf"
      [[ "$peer_ip" == "$prefix"* ]] || die "Peer $(basename "$pf" .conf) dùng $peer_ip ngoài subnet ${prefix}0/24. Hãy sửa/gỡ peer trước khi đổi subnet EXIT."
      [[ "$peer_ip" != "$exit_ip" ]] || die "Peer $(basename "$pf" .conf) trùng EXIT tunnel IP $exit_ip."
    done
  fi
}

txn_save_file(){
  local src="$1" tag="$2"
  if [[ -e "$src" ]]; then
    printf '1\n' >"$TXN_DIR/${tag}.exists"
    cp -af "$src" "$TXN_DIR/$tag"
  else
    printf '0\n' >"$TXN_DIR/${tag}.exists"
  fi
}

txn_restore_file(){
  local dst="$1" tag="$2" existed="0"
  [[ -f "$TXN_DIR/${tag}.exists" ]] && existed=$(cat "$TXN_DIR/${tag}.exists")
  if [[ "$existed" == "1" && -e "$TXN_DIR/$tag" ]]; then
    cp -af "$TXN_DIR/$tag" "$dst"
  else
    rm -f "$dst"
  fi
}

begin_exit_transaction(){
  local was_enabled="$1" was_active="$2" runtime_forward="$3"
  rm -rf "$TXN_DIR"
  mkdir -p "$TXN_DIR"
  chmod 700 "$TXN_DIR"
  printf '%s\n' "$was_enabled" >"$TXN_DIR/service_enabled"
  printf '%s\n' "$was_active" >"$TXN_DIR/service_active"
  printf '%s\n' "$runtime_forward" >"$TXN_DIR/ip_forward_runtime"
  txn_save_file "$CONF" ytwg0.conf
  txn_save_file "$BASE_CONF" exit-base.env
  txn_save_file "$SYSCTL" sysctl.conf
  txn_save_file "$ROLE_FILE" role
  if [[ -d "$PEERS" ]]; then
    printf '1\n' >"$TXN_DIR/peers.exists"
    cp -a "$PEERS" "$TXN_DIR/peers"
  else
    printf '0\n' >"$TXN_DIR/peers.exists"
  fi
  sync
}

install_recovery_service(){
  local self="/usr/local/lib/yt-v7/yt-exit.sh"
  [[ -x "$self" ]] || self="$(readlink -f "$0" 2>/dev/null || echo "$0")"
  cat > /etc/systemd/system/yt-v7-recovery.service <<EOF
[Unit]
Description=YT V7 EXIT interrupted-update recovery
DefaultDependencies=no
After=local-fs.target
Before=wg-quick@${IF}.service network-online.target
ConditionPathIsDirectory=${TXN_DIR}

[Service]
Type=oneshot
ExecStart=${self} recover-transaction

[Install]
WantedBy=multi-user.target
EOF
  mkdir -p "/etc/systemd/system/wg-quick@${IF}.service.d"
  cat > "/etc/systemd/system/wg-quick@${IF}.service.d/10-yt-v7-recovery.conf" <<EOF
[Unit]
Wants=yt-v7-recovery.service
After=yt-v7-recovery.service
EOF
  systemctl daemon-reload
  systemctl enable yt-v7-recovery.service >/dev/null 2>&1 || true
}

commit_exit_transaction(){ rm -rf "$TXN_DIR"; }

recover_exit_transaction(){
  [[ -d "$TXN_DIR" ]] || return 0
  echo "[RECOVERY] Phát hiện lần update EXIT trước bị gián đoạn; đang khôi phục trạng thái cũ..."

  local was_enabled="disabled" was_active="inactive" runtime_forward="0"
  [[ -f "$TXN_DIR/service_enabled" ]] && was_enabled=$(cat "$TXN_DIR/service_enabled")
  [[ -f "$TXN_DIR/service_active" ]] && was_active=$(cat "$TXN_DIR/service_active")
  [[ -f "$TXN_DIR/ip_forward_runtime" ]] && runtime_forward=$(cat "$TXN_DIR/ip_forward_runtime")

  systemctl stop "wg-quick@$IF" >/dev/null 2>&1 || true
  txn_restore_file "$CONF" ytwg0.conf
  txn_restore_file "$BASE_CONF" exit-base.env
  txn_restore_file "$SYSCTL" sysctl.conf
  txn_restore_file "$ROLE_FILE" role
  local peers_existed="0"
  [[ -f "$TXN_DIR/peers.exists" ]] && peers_existed=$(cat "$TXN_DIR/peers.exists")
  rm -rf "$PEERS"
  if [[ "$peers_existed" == "1" && -d "$TXN_DIR/peers" ]]; then
    cp -a "$TXN_DIR/peers" "$PEERS"
  else
    mkdir -p "$PEERS"
  fi
  sysctl -w "net.ipv4.ip_forward=$runtime_forward" >/dev/null 2>&1 || true
  restore_exit_service_state "$was_enabled" "$was_active"
  rm -rf "$TXN_DIR"
  echo "[RECOVERY] Đã khôi phục EXIT về trạng thái trước update."
}

install_exit(){
  [[ $EUID -eq 0 ]] || die "Chạy root"
  recover_exit_transaction
  local wg_was_enabled wg_was_active
  wg_was_enabled=$(systemctl is-enabled "wg-quick@$IF" 2>/dev/null || true)
  wg_was_active=$(systemctl is-active "wg-quick@$IF" 2>/dev/null || true)
  ensure_deps
  role_guard
  collision_guard
  command -v python3 >/dev/null || install_missing python3

  local port eip oif before after oldf runtime_forward
  local conf_bak="" base_bak="" first_install=0
  [[ -f "$ROLE_FILE" ]] || first_install=1

  read -rp "Port [44443]: " port
  port=${port:-44443}
  read -rp "EXIT tunnel IP [10.88.0.1]: " eip
  eip=${eip:-10.88.0.1}

  valid_port "$port" || die "Port sai"
  valid_ipv4 "$eip" || die "IP sai"
  validate_all_peer_ips_in_subnet "$eip"

  oif=$(ip route show default | awk 'NR==1{for(i=1;i<=NF;i++)if($i=="dev"){print $(i+1);exit}}')
  [[ -n "$oif" ]] || die "Không có OUT IF"

  mkdir -p "$STATE" "$PEERS" /etc/wireguard
  chmod 700 "$STATE" "$PEERS" /etc/wireguard

  [[ -s "$STATE/exit.key" ]] || (umask 077; wg genkey >"$STATE/exit.key")
  wg pubkey <"$STATE/exit.key" >"$STATE/exit.pub"

  runtime_forward=$(sysctl -n net.ipv4.ip_forward 2>/dev/null || echo 0)
  oldf="$runtime_forward"

  install_recovery_service

  # Snapshot persistent state BEFORE peer synchronization or active-tunnel mutation.
  begin_exit_transaction "$wg_was_enabled" "$wg_was_active" "$runtime_forward"

  # Preserve currently-working runtime peer keys before rebuilding config.
  sync_peer_state_from_runtime

  if [[ -f "$CONF" ]]; then
    conf_bak="$CONF.bak.$(date +%s)"
    cp -a "$CONF" "$conf_bak"
  fi

  # If updating an active EXIT, stop it BEFORE replacing the config.
  # This makes wg-quick run PostDown from the OLD config and prevents stale NAT/FORWARD rules.
  if [[ "$wg_was_active" == "active" && -n "$conf_bak" ]]; then
    systemctl stop "wg-quick@$IF" || die "Không stop được EXIT cũ trước update; giữ nguyên config cũ."
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

    sysctl -w "net.ipv4.ip_forward=$runtime_forward" >/dev/null 2>&1 || true

    restore_exit_service_state "$wg_was_enabled" "$wg_was_active"
    commit_exit_transaction

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

    sysctl -w "net.ipv4.ip_forward=$runtime_forward" >/dev/null 2>&1 || true

    restore_exit_service_state "$wg_was_enabled" "$wg_was_active"
    commit_exit_transaction

    die "Default route đổi; đã rollback EXIT."
  fi

  [[ -z "$conf_bak" ]] || rm -f "$conf_bak"
  [[ -z "$base_bak" ]] || rm -f "$base_bak"

  systemctl enable "wg-quick@$IF" >/dev/null 2>&1 || die "Không thể enable wg-quick@$IF"
  systemctl is-active --quiet "wg-quick@$IF" || systemctl start "wg-quick@$IF" >/dev/null 2>&1 || die "Không thể start wg-quick@$IF"
  systemctl is-enabled --quiet "wg-quick@$IF" || die "wg-quick@$IF chưa enabled sau apply."
  systemctl is-active --quiet "wg-quick@$IF" || die "wg-quick@$IF chưa active sau apply."

  commit_exit_transaction
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
  [[ "$mip" == "${EXIT_IP%.*}."* ]] || die "MAIN tunnel IP $mip phải nằm trong subnet ${EXIT_IP%.*}.0/24 của EXIT"

  # Prevent ambiguous WireGuard peer state: the same public key or tunnel IP
  # must not be owned by another peer file.
  local pf other_pub other_ip
  if compgen -G "$PEERS/*.conf" >/dev/null; then
    for pf in "$PEERS"/*.conf; do
      [[ "$pf" == "$PEERS/$n.conf" ]] && continue
      other_pub=$(awk -F' *= *' '$1=="PublicKey"{print $2}' "$pf" 2>/dev/null || true)
      other_ip=$(awk -F' *= *' '$1=="AllowedIPs"{sub(/\/32$/, "", $2); print $2}' "$pf" 2>/dev/null || true)
      [[ "$other_pub" != "$pub" ]] || die "MAIN Public Key đã được peer khác sử dụng: $(basename "$pf" .conf)"
      [[ "$other_ip" != "$mip" ]] || die "Tunnel IP $mip đã được peer khác sử dụng: $(basename "$pf" .conf)"
    done
  fi

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
  local hs=0 i latest now age
  for i in {1..7}; do
    latest=$(wg show "$IF" latest-handshakes 2>/dev/null | awk -v k="$pub" '$1==k {print $2}')
    now=$(date +%s)
    if [[ "$latest" =~ ^[0-9]+$ ]] && (( latest > 0 )); then
      age=$((now-latest))
      if (( age >= 0 && age <= 40 )); then
        hs=1
        break
      fi
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
 rm -f /etc/systemd/system/yt-v7-recovery.service
 rm -rf "/etc/systemd/system/wg-quick@${IF}.service.d"
 systemctl daemon-reload >/dev/null 2>&1 || true
 # Do not force forwarding OFF on uninstall: another service may now depend on it.
 # If it was already ON before YT, keep it ON. If it was OFF, leave the current
 # runtime value unchanged after removing YT's sysctl file.
 if [[ "$old" == "1" ]]; then
   sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1 || true
 fi
 rm -rf "$STATE"; ok "Đã gỡ EXIT; không ép tắt ip_forward để tránh ảnh hưởng dịch vụ khác."
}
menu(){ while true; do echo "YT V7 EXIT $VERSION"; echo "1) Cài/Cập nhật EXIT"; echo "2) Thêm/Cập nhật MAIN"; echo "3) Trạng thái"; echo "4) Gỡ"; echo "0) Thoát"; read -rp "Chọn: " x; case $x in 1) install_exit;;2)add_main;;3)status;;4)uninstall_exit;;0)exit;;esac; done; }
case "${1:-menu}" in
  install) install_exit;;
  add-main) add_main;;
  status) status;;
  uninstall) uninstall_exit;;
  recover-transaction)
    [[ $EUID -eq 0 ]] || exit 1
    recover_exit_transaction
    ;;
  *) menu;;
esac
