#!/usr/bin/env bash
set -Eeuo pipefail
V=2.1.13; IF=ytwg0; DIR=/etc/wireguard; CONF=$DIR/$IF.conf; SD=/etc/yt7-unified

state_preflight(){
  local role="$1"
  case "$role" in
    EXIT)
      [ ! -e "$SD/exit" ] || die "State cũ tồn tại: $SD/exit. Hãy kiểm tra/gỡ thủ công trước khi setup EXIT mới."
      [ ! -e "$SD/main" ] || die "VPS này đã có MAIN state: $SD/main. Không setup EXIT chồng lên cùng VPS."
      ;;
    MAIN)
      [ ! -e "$SD/main" ] || die "State cũ tồn tại: $SD/main. Hãy kiểm tra/gỡ thủ công trước khi setup MAIN mới."
      [ ! -e "$SD/exit" ] || die "VPS này đã có EXIT state: $SD/exit. Không setup MAIN chồng lên cùng VPS."
      ;;
    *)
      die "state_preflight role không hợp lệ: $role"
      ;;
  esac
}
TABLE=1788; PRIO=17880; PORT=44443
ok(){ echo "[OK] $*"; }; die(){ echo "[ERROR] $*" >&2; exit 1; }
root(){ [ "$(id -u)" = 0 ] || die "Chạy bằng root"; }
need_cmds(){
  local c
  for c in id ip awk grep sed cut tr head cat cp mv rm mktemp sha256sum systemctl chmod chown stat mkdir rmdir sleep readlink; do
    command -v "$c" >/dev/null 2>&1 || die "Thiếu lệnh bắt buộc: $c"
  done
}
need_wg_cmds(){
  local c
  for c in wg wg-quick; do
    command -v "$c" >/dev/null 2>&1 || die "Thiếu lệnh WireGuard bắt buộc: $c"
  done
}
need_exit_cmds(){
  local c
  for c in sysctl iptables iptables-save; do
    command -v "$c" >/dev/null 2>&1 || die "Thiếu lệnh EXIT bắt buộc: $c"
  done
}
need_test_cmds(){
  command -v ping >/dev/null 2>&1 || die "Thiếu lệnh ping (gói iputils-ping); chưa thể chạy test-main."
  command -v curl >/dev/null 2>&1 || die "Thiếu lệnh curl; chưa thể xác minh Internet egress qua EXIT."
}
backup_dir=""
created_wg_conf=0
started_wg=0
created_policy_script=0
created_policy_service=0
created_rule=0
created_table_routes=0
created_sysctl=0
created_main_state=0
created_exit_state=0
created_wg_key=0
created_wg_pub=0
owned_exit_iptables=0
TX_MAIN_IP=""
TX_IP_FORWARD=""
TX_WAN_IF=""

txn_active=0
txn_committed=0
created_wg_dir=0
changed_wg_dir_mode=0
old_wg_dir_mode=""

rollback_resources(){
  echo "[ROLLBACK] Hoàn tác tài nguyên do lần chạy này tạo..." >&2

  if [ "$created_policy_service" = 1 ]; then
    systemctl disable --now yt7-main-policy.service >/dev/null 2>&1 || true
    rm -f /etc/systemd/system/yt7-main-policy.service
  fi
  if [ "$created_policy_script" = 1 ]; then
    rm -f /usr/local/sbin/yt7-main-policy.sh
  fi
  if [ "$created_rule" = 1 ] && [ -n "${TX_MAIN_IP:-}" ]; then
    ip rule del pref "$PRIO" from "$TX_MAIN_IP/32" lookup "$TABLE" >/dev/null 2>&1 || true
  fi
  if [ "$created_table_routes" = 1 ] && [ -n "${TX_MAIN_IP:-}" ]; then
    ip route del table "$TABLE" default dev "$IF" src "$TX_MAIN_IP" >/dev/null 2>&1 || true
    ip route del table "$TABLE" 10.88.0.0/24 dev "$IF" src "$TX_MAIN_IP" >/dev/null 2>&1 || true
  fi
  if [ "$started_wg" = 1 ]; then
    # wg-quick PreDown là owner chính của cleanup iptables.
    systemctl disable --now "wg-quick@$IF" >/dev/null 2>&1 || true
  fi
  if [ "$owned_exit_iptables" = 1 ] && [ -n "${TX_WAN_IF:-}" ] && command -v iptables >/dev/null 2>&1; then
    # Fallback chỉ exact-delete rule YT7 nếu nó thực sự còn tồn tại.
    if iptables -t nat -C POSTROUTING -s 10.88.0.0/24 -o "$TX_WAN_IF" -m comment --comment YT7_EXIT_MASQ -j MASQUERADE >/dev/null 2>&1; then
      iptables -t nat -D POSTROUTING -s 10.88.0.0/24 -o "$TX_WAN_IF" -m comment --comment YT7_EXIT_MASQ -j MASQUERADE >/dev/null 2>&1 || true
    fi
    if iptables -C FORWARD -i "$IF" -o "$TX_WAN_IF" -m comment --comment YT7_EXIT_FWD_OUT -j ACCEPT >/dev/null 2>&1; then
      iptables -D FORWARD -i "$IF" -o "$TX_WAN_IF" -m comment --comment YT7_EXIT_FWD_OUT -j ACCEPT >/dev/null 2>&1 || true
    fi
    if iptables -C FORWARD -i "$TX_WAN_IF" -o "$IF" -m conntrack --ctstate RELATED,ESTABLISHED -m comment --comment YT7_EXIT_FWD_IN -j ACCEPT >/dev/null 2>&1; then
      iptables -D FORWARD -i "$TX_WAN_IF" -o "$IF" -m conntrack --ctstate RELATED,ESTABLISHED -m comment --comment YT7_EXIT_FWD_IN -j ACCEPT >/dev/null 2>&1 || true
    fi
  fi
  if [ "$created_wg_conf" = 1 ]; then rm -f "$CONF"; fi
  if [ "$created_wg_pub" = 1 ]; then rm -f "$DIR/$IF.pub"; fi
  if [ "$created_wg_key" = 1 ]; then rm -f "$DIR/$IF.key"; fi
  if [ "$created_sysctl" = 1 ]; then
    rm -f /etc/sysctl.d/99-yt7-forward.conf
    if [ -n "${TX_IP_FORWARD:-}" ]; then
      sysctl -w "net.ipv4.ip_forward=$TX_IP_FORWARD" >/dev/null 2>&1 || true
    fi
  fi
  if [ "$created_main_state" = 1 ]; then rm -f "$SD/main"; fi
  if [ "$created_exit_state" = 1 ]; then rm -f "$SD/exit"; fi
  rmdir "$SD" >/dev/null 2>&1 || true

  if [ "$changed_wg_dir_mode" = 1 ] && [ -n "${old_wg_dir_mode:-}" ] && [ -d "$DIR" ]; then
    chmod "$old_wg_dir_mode" "$DIR" >/dev/null 2>&1 || true
  fi
  if [ "$created_wg_dir" = 1 ]; then
    rmdir "$DIR" >/dev/null 2>&1 || true
  fi

  [ -n "${backup_dir:-}" ] && rm -rf "$backup_dir" >/dev/null 2>&1 || true
  backup_dir=""
  systemctl daemon-reload >/dev/null 2>&1 || true
  echo "[ROLLBACK] Hoàn tất; không quét/xóa tài nguyên ngoài phần YT7 do transaction này sở hữu." >&2
}

txn_on_exit(){
  local rc=$1
  trap - EXIT HUP INT TERM
  if [ "$txn_active" = 1 ] && [ "$txn_committed" != 1 ]; then
    # Nếu có exit 0 bất ngờ trước commit, vẫn coi transaction là thất bại.
    [ "$rc" -ne 0 ] || rc=1
    rollback_resources
  fi
  exit "$rc"
}

begin_txn(){
  backup_dir=$(mktemp -d /tmp/yt7.XXXXXX)
  txn_active=1
  txn_committed=0
  trap 'txn_on_exit $?' EXIT
  trap 'exit 129' HUP
  trap 'exit 130' INT
  trap 'exit 143' TERM
}

commit_txn(){
  txn_committed=1
  txn_active=0
  trap - EXIT HUP INT TERM
  [ -n "${backup_dir:-}" ] && rm -rf "$backup_dir"
  backup_dir=""
}
ipv4_to_u32(){
  local ip=$1 IFS=. a b c d extra
  read -r a b c d extra <<<"$ip"
  [ -z "${extra:-}" ] || return 1
  for x in "$a" "$b" "$c" "$d"; do
    [[ "$x" =~ ^[0-9]{1,3}$ ]] || return 1
    ((10#$x >= 0 && 10#$x <= 255)) || return 1
  done
  printf '%u\n' "$(( (10#$a<<24) | (10#$b<<16) | (10#$c<<8) | 10#$d ))"
}
cidr_overlap(){
  local c1=$1 c2=$2 ip1 p1 ip2 p2 n1 n2 mask1 mask2 net1 net2
  ip1=${c1%/*}; p1=${c1#*/}
  ip2=${c2%/*}; p2=${c2#*/}
  [[ "$p1" =~ ^[0-9]+$ ]] && ((p1>=0 && p1<=32)) || return 1
  [[ "$p2" =~ ^[0-9]+$ ]] && ((p2>=0 && p2<=32)) || return 1
  n1=$(ipv4_to_u32 "$ip1") || return 1
  n2=$(ipv4_to_u32 "$ip2") || return 1
  if ((p1==0)); then mask1=0; else mask1=$(( (0xFFFFFFFF << (32-p1)) & 0xFFFFFFFF )); fi
  if ((p2==0)); then mask2=0; else mask2=$(( (0xFFFFFFFF << (32-p2)) & 0xFFFFFFFF )); fi
  net1=$(( n1 & mask1 )); net2=$(( n2 & mask2 ))
  # Two networks overlap iff each network start is <= the other's network end.
  local end1=$(( net1 | ((~mask1) & 0xFFFFFFFF) ))
  local end2=$(( net2 | ((~mask2) & 0xFFFFFFFF) ))
  (( net1 <= end2 && net2 <= end1 ))
}
subnet_conflict(){
  local target="$1" ifname="${2:-$IF}" line token cidr
  while IFS= read -r line; do
    [[ "$line" =~ (^|[[:space:]])dev[[:space:]]+$ifname([[:space:]]|$) ]] && continue
    for token in $line; do
      cidr=""
      if [[ "$token" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/[0-9]{1,2}$ ]]; then
        cidr="$token"
      elif [[ "$token" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
        # Host route without an explicit prefix.
        cidr="$token/32"
      fi
      [ -n "$cidr" ] || continue
      if cidr_overlap "$target" "$cidr"; then
        echo "[CONFLICT] $target overlaps existing route/address: $line" >&2
        return 0
      fi
      # Only the destination field matters. Avoid treating gateway/src IPs
      # later in the route line as destination networks.
      break
    done
  done < <(ip -4 route show table all 2>/dev/null)

  # Also inspect assigned addresses, including cases that do not currently
  # have a normal main-table route.
  while IFS= read -r cidr; do
    [ -n "$cidr" ] || continue
    if cidr_overlap "$target" "$cidr"; then
      echo "[CONFLICT] $target overlaps assigned address/network: $cidr" >&2
      return 0
    fi
  done < <(ip -o -4 addr show 2>/dev/null | awk -v i="$ifname" '$2!=i {print $4}')
  return 1
}
wait_handshake(){
  local tries=12 h
  while ((tries--)); do
    h=$(wg show "$IF" latest-handshakes 2>/dev/null | awk 'NR==1{print $2}')
    if [ -n "$h" ] && [ "$h" != "0" ]; then return 0; fi
    sleep 1
  done
  return 1
}
wg_name_preflight(){
  ip link show "$IF" >/dev/null 2>&1 && die "Interface $IF đã tồn tại; không đụng vào."
  systemctl is-active --quiet "wg-quick@$IF" 2>/dev/null && die "wg-quick@$IF đang active; không đụng vào."
  systemctl is-enabled --quiet "wg-quick@$IF" 2>/dev/null && die "wg-quick@$IF đã enabled; không đụng vào."
  [ ! -e "$DIR/$IF.key" ] || die "$DIR/$IF.key đã tồn tại; không đụng vào."
  [ ! -e "$DIR/$IF.pub" ] || die "$DIR/$IF.pub đã tồn tại; không đụng vào."
}
valid_main_tunnel_ip(){
  local ip=$1 last
  validip "$ip" || return 1
  [[ "$ip" == 10.88.0.* ]] || return 1
  last=${ip##*.}
  ((10#$last >= 2 && 10#$last <= 254))
}

postcheck_exit(){
  local expected_port=$1 expected_default=$2
  systemctl is-active --quiet "wg-quick@$IF" || die "Post-check EXIT: wg-quick@$IF không active."
  ip -4 addr show dev "$IF" | grep -Eq 'inet[[:space:]]+10\.88\.0\.1/24([[:space:]]|$)' || die "Post-check EXIT: thiếu 10.88.0.1/24."
  [ "$(cat /sys/class/net/$IF/mtu 2>/dev/null)" = "1420" ] || die "Post-check EXIT: MTU runtime không phải 1420."
  wg show "$IF" listen-port 2>/dev/null | grep -qx "$expected_port" || die "Post-check EXIT: ListenPort runtime sai."
  [ "$(defroute)" = "$expected_default" ] || die "Post-check EXIT: default route thay đổi."
  sysctl -n net.ipv4.ip_forward 2>/dev/null | grep -qx '1' || die "Post-check EXIT: ip_forward chưa bật."
  iptables-save 2>/dev/null | grep -q 'YT7_EXIT_MASQ' || die "Post-check EXIT: thiếu NAT rule YT7."
  iptables-save 2>/dev/null | grep -q 'YT7_EXIT_FWD_OUT' || die "Post-check EXIT: thiếu FORWARD out rule YT7."
  iptables-save 2>/dev/null | grep -q 'YT7_EXIT_FWD_IN' || die "Post-check EXIT: thiếu FORWARD return rule YT7."
}

postcheck_main(){
  local main_ip=$1 expected_default=$2 expected_pid=$3 expected_sha=$4 expected_bin_sha=$5 expected_bin_path=$6 current_bin_path
  [ -n "$expected_sha" ] || die "Post-check MAIN: SHA config ban đầu rỗng."
  [ -n "$expected_bin_sha" ] || die "Post-check MAIN: SHA binary ban đầu rỗng."
  [ -n "$expected_bin_path" ] || die "Post-check MAIN: đường dẫn binary ban đầu rỗng."
  systemctl is-active --quiet v2node || die "Post-check MAIN: V2Node không active."
  systemctl is-active --quiet "wg-quick@$IF" || die "Post-check MAIN: wg-quick@$IF không active."
  systemctl is-active --quiet yt7-main-policy.service || die "Post-check MAIN: policy service không active."
  ip -4 addr show dev "$IF" | grep -Eq "inet[[:space:]]+${main_ip//./\\.}/24([[:space:]]|$)" || die "Post-check MAIN: tunnel IP runtime sai."
  [ "$(cat /sys/class/net/$IF/mtu 2>/dev/null)" = "1420" ] || die "Post-check MAIN: MTU runtime không phải 1420."
  ip -4 rule show | grep -Eq "^${PRIO}:[[:space:]]+from ${main_ip//./\\.} lookup ${TABLE}([[:space:]]|$)" || die "Post-check MAIN: thiếu policy rule."
  ip -4 route show table "$TABLE" | grep -Eq "^default dev $IF scope link src ${main_ip//./\\.}$" || die "Post-check MAIN: default table $TABLE sai."
  ip -4 route show table "$TABLE" | grep -Eq "^10\.88\.0\.0/24 dev $IF scope link src ${main_ip//./\\.}$" || die "Post-check MAIN: subnet route table $TABLE sai."
  [ "$(defroute)" = "$expected_default" ] || die "Post-check MAIN: default route hệ thống thay đổi."
  [ "$(systemctl show v2node -p MainPID --value 2>/dev/null||echo 0)" = "$expected_pid" ] || die "Post-check MAIN: V2Node PID thay đổi."
  [ "$(sha256sum /etc/v2node/config.json 2>/dev/null|awk '{print $1}'||true)" = "$expected_sha" ] || die "Post-check MAIN: /etc/v2node/config.json thay đổi."
  current_bin_path=$(readlink -f "/proc/$expected_pid/exe" 2>/dev/null || true)
  [ "$current_bin_path" = "$expected_bin_path" ] || die "Post-check MAIN: executable V2Node đang chạy thay đổi."
  [ "$(sha256sum "$expected_bin_path" 2>/dev/null|awk '{print $1}'||true)" = "$expected_bin_sha" ] || die "Post-check MAIN: binary V2Node thay đổi."
  ip -4 route get 1.1.1.1 | grep -q "dev $IF" && die "Post-check MAIN: traffic thường bị đưa vào tunnel."
  ip -4 route get 1.1.1.1 from "$main_ip" | grep -q "dev $IF" || die "Post-check MAIN: source $main_ip chưa đi tunnel."
}
defroute(){ ip -4 route show default|head -1; }
wan(){ ip -4 route show default|awk 'NR==1{for(i=1;i<=NF;i++)if($i=="dev"){print $(i+1);exit}}'; }
validip(){
  local ip=$1 IFS=. a b c d extra
  read -r a b c d extra <<<"$ip"
  [ -z "${extra:-}" ] || return 1
  for oct in "$a" "$b" "$c" "$d"; do
    [[ "$oct" =~ ^[0-9]{1,3}$ ]] || return 1
    ((10#$oct >= 0 && 10#$oct <= 255)) || return 1
  done
}
deps(){
 if ! command -v wg >/dev/null || ! command -v iptables >/dev/null; then
   command -v apt-get >/dev/null || die "Chỉ hỗ trợ Debian/Ubuntu apt"
   apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y wireguard-tools iptables
 fi
}
keys(){
  if [ ! -d "$DIR" ]; then
    created_wg_dir=1
    mkdir -p "$DIR"
  else
    old_wg_dir_mode=$(stat -c '%a' "$DIR" 2>/dev/null || true)
    if [ "$old_wg_dir_mode" != "700" ]; then
      changed_wg_dir_mode=1
      chmod 700 "$DIR"
    fi
  fi
  chmod 700 "$DIR"
  umask 077
  created_wg_key=1
  wg genkey >"$DIR/$IF.key"
  created_wg_pub=1
  wg pubkey <"$DIR/$IF.key" >"$DIR/$IF.pub"
}
setup_exit(){
 root; need_cmds
 state_preflight EXIT
 [ ! -e "$CONF" ] || die "$CONF đã tồn tại; không ghi đè."
 subnet_conflict "10.88.0.0/24" && die "Phát hiện route 10.88.0.0/24 đang dùng bởi interface khác."
 [ ! -e /etc/sysctl.d/99-yt7-forward.conf ] || die "/etc/sysctl.d/99-yt7-forward.conf đã tồn tại; không ghi đè."
 wg_name_preflight
 local W P B PRIV PUB
 W=$(wan); P=${1:-$PORT}; B=$(defroute); [ -n "$W" ] || die "Không thấy WAN"
 [[ "$P" =~ ^[0-9]+$ ]] && [ "$P" -ge 1 ] && [ "$P" -le 65535 ] || die "UDP port không hợp lệ."

 # Chỉ sau preflight read-only mới cài dependency nếu máy còn thiếu.
 deps
 need_wg_cmds
 need_exit_cmds

 # Không dùng/chia sẻ rule iptables có sẵn của hệ thống khác.
 if iptables-save 2>/dev/null | grep -q 'YT7_EXIT_'; then
   die "Phát hiện iptables rule mang nhãn YT7_EXIT_ đã tồn tại; không đụng vào."
 fi

 TX_WAN_IF="$W"
 TX_IP_FORWARD=$(sysctl -n net.ipv4.ip_forward 2>/dev/null || echo 0)
 begin_txn
 keys; PRIV=$(cat "$DIR/$IF.key"); PUB=$(cat "$DIR/$IF.pub")
 created_wg_conf=1
 cat >"$CONF" <<EOF
[Interface]
MTU = 1420
Address = 10.88.0.1/24
ListenPort = $P
PrivateKey = $PRIV
Table = off
PostUp = iptables -t nat -A POSTROUTING -s 10.88.0.0/24 -o $W -m comment --comment YT7_EXIT_MASQ -j MASQUERADE
PostUp = iptables -A FORWARD -i %i -o $W -m comment --comment YT7_EXIT_FWD_OUT -j ACCEPT
PostUp = iptables -A FORWARD -i $W -o %i -m conntrack --ctstate RELATED,ESTABLISHED -m comment --comment YT7_EXIT_FWD_IN -j ACCEPT
PreDown = iptables -t nat -D POSTROUTING -s 10.88.0.0/24 -o $W -m comment --comment YT7_EXIT_MASQ -j MASQUERADE 2>/dev/null || true
PreDown = iptables -D FORWARD -i %i -o $W -m comment --comment YT7_EXIT_FWD_OUT -j ACCEPT 2>/dev/null || true
PreDown = iptables -D FORWARD -i $W -o %i -m conntrack --ctstate RELATED,ESTABLISHED -m comment --comment YT7_EXIT_FWD_IN -j ACCEPT 2>/dev/null || true
EOF
 chmod 600 "$CONF"
 created_sysctl=1
 echo 'net.ipv4.ip_forward=1'>/etc/sysctl.d/99-yt7-forward.conf
 sysctl -w net.ipv4.ip_forward=1 >/dev/null
 owned_exit_iptables=1
 started_wg=1
 systemctl enable --now wg-quick@$IF
 [ "$(defroute)" = "$B" ] || die "Default route EXIT thay đổi."
 created_exit_state=1
 mkdir -p "$SD"; chmod 700 "$SD"; printf "ROLE=EXIT\nWAN=%s\nPORT=%s\n" "$W" "$P">"$SD/exit"
 postcheck_exit "$P" "$B"
 commit_txn; ok "EXIT sẵn sàng"; echo "EXIT_WG_PUBLIC_KEY=$PUB"; echo "EXIT_PORT=$P"; echo "EXIT_TUNNEL_IP=10.88.0.1"
}
setup_main(){
 root; need_cmds
 state_preflight MAIN
 [ ! -e "$CONF" ] || die "$CONF đã tồn tại; không ghi đè."
 subnet_conflict "10.88.0.0/24" && die "Phát hiện route 10.88.0.0/24 đang dùng bởi interface khác."
 [ ! -e /usr/local/sbin/yt7-main-policy.sh ] || die "Policy script đã tồn tại; không ghi đè."
 [ ! -e /etc/systemd/system/yt7-main-policy.service ] || die "Policy service đã tồn tại; không ghi đè."
 wg_name_preflight
 local E K M P B PRIV PUB PID SHA BIN_SHA BIN_PATH
 E=${1:-}; K=${2:-}; M=${3:-}; P=${4:-$PORT}
 [ -n "$E" ]||read -rp "Public IP EXIT: " E
 [ -n "$K" ]||read -rp "WG Public Key EXIT: " K
 [ -n "$M" ]||read -rp "Tunnel IP MAIN (10.88.0.2..254): " M
 validip "$E" >/dev/null || die "EXIT IP sai"
 valid_main_tunnel_ip "$M" || die "Tunnel IP MAIN phải nằm trong 10.88.0.2..10.88.0.254"
 ip rule show|grep -q "^$PRIO:" && die "Priority $PRIO đang dùng"
 [ -z "$(ip route show table $TABLE 2>/dev/null)" ]||die "Table $TABLE đang dùng"
 [[ "$K" =~ ^[A-Za-z0-9+/]{43}=$ ]] || die "WireGuard Public Key EXIT không hợp lệ."
 [[ "$P" =~ ^[0-9]+$ ]] && [ "$P" -ge 1 ] && [ "$P" -le 65535 ] || die "UDP port không hợp lệ."
 B=$(defroute)
 [ -n "$B" ] || die "MAIN không có IPv4 default route; không tiếp tục."
 PID=$(systemctl show v2node -p MainPID --value 2>/dev/null||echo 0)
 systemctl is-active --quiet v2node || die "V2Node hiện không active; dừng trước khi thay đổi mạng."
 [[ "$PID" =~ ^[0-9]+$ ]] && [ "$PID" -gt 0 ] || die "Không lấy được MainPID hợp lệ của V2Node."
 BIN_PATH=$(readlink -f "/proc/$PID/exe" 2>/dev/null || true)
 [ -n "$BIN_PATH" ] && [ -f "$BIN_PATH" ] || die "Không xác định được executable thực tế của V2Node từ /proc/$PID/exe."
 [ -x "$BIN_PATH" ] || die "Executable V2Node không có quyền thực thi: $BIN_PATH"
 [ -f /etc/v2node/config.json ] || die "Không tìm thấy /etc/v2node/config.json; dừng để tránh bảo vệ sai đường dẫn."
 BIN_SHA=$(sha256sum "$BIN_PATH" 2>/dev/null | awk '{print $1}')
 SHA=$(sha256sum /etc/v2node/config.json 2>/dev/null | awk '{print $1}')
 [ -n "$BIN_SHA" ] || die "Không đọc được SHA256 binary V2Node."
 [ -n "$SHA" ] || die "Không đọc được SHA256 config V2Node."

 # Chỉ sau preflight read-only mới cài dependency nếu máy còn thiếu.
 deps
 need_wg_cmds

 TX_MAIN_IP="$M"
 begin_txn
 keys; PRIV=$(cat "$DIR/$IF.key"); PUB=$(cat "$DIR/$IF.pub")
 created_wg_conf=1
 cat >"$CONF" <<EOF
[Interface]
MTU = 1420
Address = $M/24
PrivateKey = $PRIV
Table = off
[Peer]
PublicKey = $K
Endpoint = $E:$P
AllowedIPs = 0.0.0.0/0
PersistentKeepalive = 25
EOF
 chmod 600 "$CONF"
 started_wg=1
 systemctl enable --now wg-quick@$IF
 created_policy_script=1
 cat >/usr/local/sbin/yt7-main-policy.sh <<EOF
#!/usr/bin/env bash
set -Eeuo pipefail
RULE="$PRIO"
TABLE="$TABLE"
SRC="$M/32"
NET="10.88.0.0/24"
IF="$IF"
IP="$M"

has_rule(){
  ip -4 rule show | grep -Fq "\${RULE}:	from \${SRC%/*} lookup \${TABLE}" ||
  ip -4 rule show | grep -Eq "^\${RULE}:[[:space:]]+from \${SRC%/*} lookup \${TABLE}([[:space:]]|$)"
}
case "\${1:-apply}" in
apply)
  has_rule || ip -4 rule add pref "\$RULE" from "\$SRC" lookup "\$TABLE"
  ip -4 route replace table "\$TABLE" "\$NET" dev "\$IF" src "\$IP"
  ip -4 route replace table "\$TABLE" default dev "\$IF" src "\$IP"
  ;;
remove)
  ip -4 rule del pref "\$RULE" from "\$SRC" lookup "\$TABLE" 2>/dev/null || true
  ip -4 route del table "\$TABLE" default dev "\$IF" src "\$IP" 2>/dev/null || true
  ip -4 route del table "\$TABLE" "\$NET" dev "\$IF" src "\$IP" 2>/dev/null || true
  ;;
*)
  echo "Usage: \$0 {apply|remove}" >&2; exit 2 ;;
esac
EOF
 chmod 755 /usr/local/sbin/yt7-main-policy.sh
 created_policy_service=1
 cat >/etc/systemd/system/yt7-main-policy.service <<EOF
[Unit]
After=wg-quick@$IF.service
BindsTo=wg-quick@$IF.service
PartOf=wg-quick@$IF.service
[Service]
Type=oneshot
ExecStart=/usr/local/sbin/yt7-main-policy.sh apply
ExecStop=/usr/local/sbin/yt7-main-policy.sh remove
RemainAfterExit=yes
[Install]
WantedBy=multi-user.target
EOF
 created_rule=1; created_table_routes=1
 systemctl daemon-reload; systemctl enable --now yt7-main-policy
 [ "$(defroute)" = "$B" ]||die "Default route MAIN thay đổi"
 [ "$(systemctl show v2node -p MainPID --value 2>/dev/null||echo 0)" = "$PID" ]||die "V2Node PID thay đổi"
 [ "$(sha256sum /etc/v2node/config.json 2>/dev/null|awk '{print $1}'||true)" = "$SHA" ]||die "V2Node config thay đổi"
 created_main_state=1
 mkdir -p "$SD"; printf "ROLE=MAIN\nMAIN_IP=%s\nEXIT_IP=%s\n" "$M" "$E">"$SD/main"
 postcheck_main "$M" "$B" "$PID" "$SHA" "$BIN_SHA" "$BIN_PATH"
 commit_txn
 ok "MAIN đã tạo tunnel + policy an toàn; cần add-peer trên EXIT rồi chạy test-main."
 echo "MAIN_WG_PUBLIC_KEY=$PUB"; echo "MAIN_TUNNEL_IP=$M"
 echo "SANG EXIT CHẠY: $0 add-peer '$PUB' '$M'"
 echo "PANEL JSON: {\"tag\":\"yt_exit\",\"sendThrough\":\"$M\",\"protocol\":\"freedom\",\"settings\":{\"domainStrategy\":\"UseIPv4\"}}"
}
add_peer(){
 root; need_cmds; need_wg_cmds
 local K=${1:-} M=${2:-}
 local TMP="" NEW="" VDIR="" VCONF="" STRIPPED=""
 local CONF_REPLACED=0 RUNTIME_ADDED=0 VALIDATE_CREATED=0 COMMITTED=0

 add_peer_cleanup(){
   local rc=${1:-1}
   trap - EXIT HUP INT TERM
   if [ "$COMMITTED" != 1 ]; then
     if [ "$VALIDATE_CREATED" = 1 ]; then
       ip link del yt7validate >/dev/null 2>&1 || true
     fi
     if [ "$RUNTIME_ADDED" = 1 ] && [ -n "${K:-}" ]; then
       wg set "$IF" peer "$K" remove >/dev/null 2>&1 || true
     fi
     if [ "$CONF_REPLACED" = 1 ] && [ -n "${TMP:-}" ] && [ -f "$TMP" ]; then
       cp -a "$TMP" "$CONF" >/dev/null 2>&1 || true
     fi
   fi
   [ -n "${VDIR:-}" ] && rm -rf "$VDIR" >/dev/null 2>&1 || true
   [ -n "${NEW:-}" ] && rm -f "$NEW" >/dev/null 2>&1 || true
   [ -n "${TMP:-}" ] && rm -f "$TMP" >/dev/null 2>&1 || true
   return "$rc"
 }

 # EXIT/HUP/INT/TERM: dọn file tạm, interface validate, runtime peer và phục hồi config nếu cần.
 trap 'rc=$?; add_peer_cleanup "$rc"; exit "$rc"' EXIT
 trap 'exit 129' HUP
 trap 'exit 130' INT
 trap 'exit 143' TERM

 command -v wg >/dev/null 2>&1 || die "Thiếu lệnh wg; EXIT chưa được cài đúng."
 [ -f "$SD/exit" ] || die "Máy này chưa có YT7 EXIT state."
 [ -f "$CONF" ] || die "Thiếu $CONF."
 [ -n "$K" ] && [ -n "$M" ] || die "add-peer PUBLIC_KEY 10.88.0.X"
 [[ "$K" =~ ^[A-Za-z0-9+/]{43}=$ ]] || die "MAIN WireGuard Public Key không hợp lệ."
 valid_main_tunnel_ip "$M" || die "MAIN tunnel IP phải nằm trong 10.88.0.2..10.88.0.254"
 systemctl is-active --quiet "wg-quick@$IF" || die "wg-quick@$IF không active trên EXIT."
 ip link show yt7validate >/dev/null 2>&1 && die "Interface tạm yt7validate đã tồn tại; không đụng vào."
 ip -4 addr show dev "$IF" 2>/dev/null | grep -Eq 'inet[[:space:]]+10\.88\.0\.1/24([[:space:]]|$)' || die "$IF không mang địa chỉ EXIT 10.88.0.1/24."
 grep -Eq '^[[:space:]]*Address[[:space:]]*=[[:space:]]*10\.88\.0\.1/24[[:space:]]*$' "$CONF" || die "$CONF không phải cấu hình EXIT 10.88.0.1/24."

 # Duplicate check trên file: không phụ thuộc khoảng trắng quanh dấu "=".
 awk -v want="$K" '
   match($0,/^[[:space:]]*PublicKey[[:space:]]*=[[:space:]]*/){
     v=substr($0,RLENGTH+1); sub(/[[:space:]]*#.*/,"",v)
     gsub(/^[[:space:]]+|[[:space:]]+$/,"",v)
     if(v==want) found=1
   }
   END{exit found?0:1}
 ' "$CONF" && die "Key đã tồn tại trong config."

 awk -v want="$M/32" '
   match($0,/^[[:space:]]*AllowedIPs[[:space:]]*=[[:space:]]*/){
     v=substr($0,RLENGTH+1); sub(/[[:space:]]*#.*/,"",v)
     n=split(v,a,",")
     for(i=1;i<=n;i++){gsub(/^[[:space:]]+|[[:space:]]+$/,"",a[i]); if(a[i]==want) found=1}
   }
   END{exit found?0:1}
 ' "$CONF" && die "IP đã được cấp trong config."

 # Duplicate check trên runtime: tránh config/runtime lệch nhau.
 wg show "$IF" peers | tr ' ' '\n' | grep -Fxq "$K" && die "Key đã tồn tại trong runtime."
 wg show "$IF" allowed-ips | awk -v want="$M/32" '
   {
     n=split($2,a,",")
     for(i=1;i<=n;i++) if(a[i]==want) found=1
   }
   END{exit found?0:1}
 ' && die "IP đã được cấp trong runtime."

 TMP=$(mktemp)
 NEW=$(mktemp "${DIR}/.${IF}.candidate.XXXXXX")
 VDIR=$(mktemp -d)
 VCONF="$VDIR/${IF}.conf"
 STRIPPED="$VDIR/stripped.conf"

 cp -a "$CONF" "$TMP"
 cat "$CONF" >"$NEW"
 cat >>"$NEW" <<EOF

# YT7 peer $M
[Peer]
PublicKey = $K
AllowedIPs = $M/32
EOF
 chmod --reference="$CONF" "$NEW" 2>/dev/null || chmod 600 "$NEW"
 chown --reference="$CONF" "$NEW" 2>/dev/null || true

 # Validate candidate bằng filename wg-quick hợp lệ rồi parse bằng wg setconf.
 cp -a "$NEW" "$VCONF"
 wg-quick strip "$VCONF" >"$STRIPPED" 2>/dev/null || die "Cấu hình peer mới không qua được wg-quick strip; chưa thay file."

 VALIDATE_CREATED=1
 ip link add dev yt7validate type wireguard >/dev/null 2>&1 || die "Không tạo được interface WireGuard tạm để validate."
 wg setconf yt7validate "$STRIPPED" >/dev/null 2>&1 || die "Cấu hình peer mới không hợp lệ; chưa thay file."
 ip link del yt7validate >/dev/null 2>&1 || die "Không xóa được interface validate tạm."
 VALIDATE_CREATED=0

 CONF_REPLACED=1
 mv -f "$NEW" "$CONF" || die "Không thể thay ytwg0.conf atomically."
 NEW=""

 RUNTIME_ADDED=1
 wg set "$IF" peer "$K" allowed-ips "$M/32" || die "wg set thất bại; transaction sẽ phục hồi ytwg0.conf."

 # Runtime post-check: peer và AllowedIPs phải đúng.
 wg show "$IF" peers | tr ' ' '\n' | grep -Fxq "$K" || die "Post-check add-peer: runtime không thấy public key."
 wg show "$IF" allowed-ips | awk -v k="$K" -v a="$M/32" '
   $1==k {
     n=split($2,x,",")
     for(i=1;i<=n;i++) if(x[i]==a) ok=1
   }
   END{exit ok?0:1}
 ' || die "Post-check add-peer: AllowedIPs runtime sai."

 # Disk post-check sau atomic replace.
 awk -v want="$K" '
   match($0,/^[[:space:]]*PublicKey[[:space:]]*=[[:space:]]*/){
     v=substr($0,RLENGTH+1); sub(/[[:space:]]*#.*/,"",v)
     gsub(/^[[:space:]]+|[[:space:]]+$/,"",v)
     if(v==want) found=1
   }
   END{exit found?0:1}
 ' "$CONF" || die "Post-check add-peer: public key không có trong config."

 awk -v want="$M/32" '
   match($0,/^[[:space:]]*AllowedIPs[[:space:]]*=[[:space:]]*/){
     v=substr($0,RLENGTH+1); sub(/[[:space:]]*#.*/,"",v)
     n=split(v,a,",")
     for(i=1;i<=n;i++){gsub(/^[[:space:]]+|[[:space:]]+$/,"",a[i]); if(a[i]==want) found=1}
   }
   END{exit found?0:1}
 ' "$CONF" || die "Post-check add-peer: AllowedIPs không có trong config."

 COMMITTED=1
 add_peer_cleanup 0
 trap - EXIT HUP INT TERM
 ok "Đã thêm peer $M atomically + runtime/config verified, không restart WireGuard"
 wg show "$IF"
}
test_main(){
  root; need_cmds; need_wg_cmds; need_test_cmds
  [ -f "$SD/main" ] || die "Chưa có MAIN state: $SD/main"
  # State file is script-owned and contains validated values only.
  # shellcheck disable=SC1090
  . "$SD/main"
  [ "${ROLE:-}" = "MAIN" ] || die "State MAIN không hợp lệ."
  valid_main_tunnel_ip "${MAIN_IP:-}" || die "MAIN_IP trong state không hợp lệ."
  validip "${EXIT_IP:-}" || die "EXIT_IP trong state không hợp lệ."

  systemctl is-active --quiet "wg-quick@$IF" || die "wg-quick@$IF không active."
  systemctl is-active --quiet yt7-main-policy.service || die "yt7-main-policy.service không active."

  # Xác minh source-policy thực sự đưa traffic có source MAIN_IP vào ytwg0.
  ip -4 route get 1.1.1.1 from "$MAIN_IP" 2>/dev/null | grep -Eq "dev[[:space:]]+$IF([[:space:]]|$)" \
    || die "Policy route lỗi: source $MAIN_IP chưa đi qua $IF."

  # Traffic bình thường của VPS không được bị hút vào tunnel.
  if ip -4 route get 1.1.1.1 2>/dev/null | grep -Eq "dev[[:space:]]+$IF([[:space:]]|$)"; then
    die "Policy route lỗi: traffic thường của MAIN đang bị đưa vào $IF."
  fi

  ping -c 2 -W 2 10.88.0.1 >/dev/null 2>&1 || die "Không ping được EXIT tunnel 10.88.0.1."

  local observed
  observed=$(curl -4fsS --interface "$IF" --connect-timeout 5 --max-time 10 https://api.ipify.org 2>/dev/null) \
    || die "Tunnel lên nhưng không xác minh được Internet egress qua EXIT."
  validip "$observed" || die "Dịch vụ kiểm tra egress trả dữ liệu không phải IPv4: $observed"

  # curl bị bind vào ytwg0 và source-policy phía trên đã được xác minh, nên
  # request thành công chứng minh Internet egress thực sự đi qua EXIT.
  # Không bắt buộc observed == EXIT_IP vì một số provider dùng NAT hoặc
  # tách ingress/egress public IP.
  if [ "$observed" = "$EXIT_IP" ]; then
    echo "[PASS] Tunnel + policy + Internet egress đúng. Public egress=$observed (trùng EXIT endpoint)."
  else
    echo "[PASS] Tunnel + policy + Internet egress đúng. Public egress=$observed"
    echo "[INFO] EXIT endpoint=$EXIT_IP nhưng egress public IP khác; có thể provider dùng NAT/tách ingress-egress."
  fi
}
panel(){
 local M=${1:-}; [ -n "$M" ]||{ [ -f "$SD/main" ]&&. "$SD/main"&&M=$MAIN_IP; }
 [ -n "$M" ]||die "panel 10.88.0.X"
 cat <<EOF
MATCH:
domain:youtube.com
domain:youtu.be
domain:googlevideo.com
domain:ytimg.com
domain:youtubei.googleapis.com
domain:youtube-nocookie.com
ACTION: 指定出站服务器(域名目标)
XRAY:
{"tag":"yt_exit","sendThrough":"$M","protocol":"freedom","settings":{"domainStrategy":"UseIPv4"}}
EOF
}
status(){ root; need_cmds; need_wg_cmds; echo "Default: $(defroute)"; systemctl is-active wg-quick@$IF 2>/dev/null||true; wg show $IF 2>/dev/null||true; ip rule show|grep "^$PRIO:"||true; ip route show table $TABLE 2>/dev/null||true; }
menu(){
 echo "YT7 Unified v$V"; echo "1) Cài EXIT mới"; echo "2) Cài MAIN mới"; echo "3) Thêm MAIN vào EXIT"; echo "4) Test MAIN"; echo "5) Status"; echo "6) In cấu hình Panel"
 read -rp "Chọn: " X
 case $X in 1) setup_exit;;2) setup_main;;3) read -rp "MAIN Public Key: " K;read -rp "MAIN tunnel IP: " M;add_peer "$K" "$M";;4)test_main;;5)status;;6)panel;;*)die "Sai lựa chọn";;esac
}
root
case ${1:-menu} in
 setup-exit) setup_exit "${2:-$PORT}";; setup-main) setup_main "${2:-}" "${3:-}" "${4:-}" "${5:-$PORT}";;
 add-peer) add_peer "${2:-}" "${3:-}";; test-main)test_main;; panel)panel "${2:-}";; status)status;; menu)menu;;
 *) die "Dùng: menu|setup-exit|setup-main|add-peer|test-main|panel|status";;
esac
