#!/usr/bin/env bash
# China Carrier Firewall - Dual Stack
# Chặn China Telecom / China Unicom / China Mobile theo ASN prefix
# Debian 12/13 - IPv4 + IPv6 - ipset + iptables/ip6tables
#
# Chế độ:
#   cn-carrier-fw                -> menu tương tác
#   cn-carrier-fw --apply-saved -> cập nhật prefix và áp dụng cấu hình đã lưu
#   cn-carrier-fw --status      -> xem trạng thái
#   cn-carrier-fw --remove      -> gỡ toàn bộ rule do script tạo
#
set -Eeuo pipefail

APP="cn-carrier-fw"
VERSION="3.4.1-lowram-safe"
INSTALL_PATH="/usr/local/sbin/cn-carrier-fw"

CONF_DIR="/etc/cn-carrier-fw"
CONF_FILE="$CONF_DIR/config"
IPSET_SAVE="$CONF_DIR/ipset.rules"
CACHE_DIR="$CONF_DIR/cache"
LOCK_FILE="$CONF_DIR/update.lock"

# Nguồn self-update. Nếu repo public, script dùng RAW_URL trực tiếp.
# Nếu repo private, có thể đặt token vào:
#   /etc/cn-carrier-fw/github_token
# hoặc export GITHUB_TOKEN trước khi chạy menu update.
GITHUB_OWNER="Luanhoangkaki"
GITHUB_REPO="NA88"
GITHUB_BRANCH="main"
GITHUB_FILE="cn-carrier-fw.sh"
RAW_URL="https://raw.githubusercontent.com/${GITHUB_OWNER}/${GITHUB_REPO}/${GITHUB_BRANCH}/${GITHUB_FILE}"
GITHUB_TOKEN_FILE="$CONF_DIR/github_token"

SET4="cncfw_block4"
SET4_NEW="cncfw_block4_new"
SET6="cncfw_block6"
SET6_NEW="cncfw_block6_new"

CHAIN_IN="CNCFW_INPUT"
CHAIN_OUT="CNCFW_OUTPUT"
CHAIN_FWD="CNCFW_FORWARD"

RESTORE_SERVICE="cn-carrier-fw-restore.service"
UPDATE_SERVICE="cn-carrier-fw-update.service"
UPDATE_TIMER="cn-carrier-fw-update.timer"

PREFIX4_FILE="$CONF_DIR/prefixes4.new"
PREFIX6_FILE="$CONF_DIR/prefixes6.new"

# ----------------------------------------------------------------------
# ASN carrier.
# Prefix IPv4 + IPv6 của các ASN này được lấy lại từ RIPEstat mỗi lần update.
# ----------------------------------------------------------------------

TELECOM_ASNS=(
  4134 4809 4811 4812 4835 23724 23764
  4847 17633 17799 17897 38283 58466 58540 58541 58543 58571 58772
  131285 132437 133775 134238 134419 134421 134425
  134760 134761 134762 134763 134764 134765 134766 134767 134769
  134770 134771 134772 134773 134774 134775
  136188 136191 136195 136198 136199
  137266 137691 137692 137693 137694 137702
  138570 138950 138982 139201 139203 139767 139887
  140053 140056 140061 140292 140293
  140308 140310 140311 140312 140313 140314 140315 140316 140317
  140318 140319 140320
  140328 140329 140330 140331 140332 140333 140334 140335 140336 140337
  140484 140494 140527 140553 140638
  141006 141679 141739 141771 146966 147038 151185 151823
  58461 136190
  # APNIC-verified China Telecom networks missing from previous DB
  4815 17638 23650 137689 140636
)

UNICOM_ASNS=(
  4837 9929 10099 4808 17621 17622 17623 17816
  134543 135061 136958 140720 140886
  # Conservative expansion: China Unicom-owned/provincial networks verified via APNIC data
  133118 133119 134542 136959 137539 138421 140726 140979 152120
)

MOBILE_ASNS=(
  9808
  56040 56041 56042 56044 56046 56047 56048
  24400 24444
  # APNIC-verified China Mobile provincial/access networks missing from previous DB
  24547 24445 38019 56045 132525 134810 141425
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

  for c in curl jq ipset iptables ip6tables flock netfilter-persistent; do
    command -v "$c" >/dev/null 2>&1 || missing=1
  done

  if [[ "$missing" -eq 1 ]] || ! dpkg -s iptables-persistent >/dev/null 2>&1; then
    log "[+] Cài gói cần thiết..."
    apt-get update -qq
    apt-get install -y -qq \
      curl jq ipset iptables iptables-persistent util-linux >/dev/null
  fi
}

install_self() {
  local source_file resolved_source
  mkdir -p "$CONF_DIR" "$CACHE_DIR"

  # BASH_SOURCE an toàn hơn $0 khi script được gọi bằng bash <(...).
  source_file="${BASH_SOURCE[0]}"
  resolved_source="$(readlink -f "$source_file" 2>/dev/null || printf '%s' "$source_file")"

  if [[ "$resolved_source" == "$INSTALL_PATH" ]]; then
    return 0
  fi

  # Không copy nhầm binary "bash" hoặc nguồn không còn tồn tại.
  if [[ ! -r "$source_file" ]]; then
    err "Không đọc được file nguồn để cài vào $INSTALL_PATH"
    err "Hãy tải script thành file rồi chạy lại."
    return 1
  fi

  # Chỉ tự cài nếu đúng script của chương trình.
  if ! grep -q '^APP="cn-carrier-fw"' "$source_file" 2>/dev/null; then
    err "Nguồn chạy hiện tại không phải script $APP; không tự ghi đè $INSTALL_PATH."
    return 1
  fi

  install -m 700 "$source_file" "$INSTALL_PATH"
}

save_choice() {
  local choice="$1" tmp
  mkdir -p "$CONF_DIR"
  tmp="$(mktemp "${CONF_DIR}/config.tmp.XXXXXX")" || return 1
  if ! printf 'CHOICE="%s"\n' "$choice" >"$tmp"; then
    rm -f "$tmp"
    return 1
  fi
  chmod 600 "$tmp" || { rm -f "$tmp"; return 1; }
  mv -f "$tmp" "$CONF_FILE"
}

load_choice() {
  local line value

  if [[ ! -f "$CONF_FILE" ]]; then
    err "Chưa có cấu hình đã lưu. Hãy chạy: $INSTALL_PATH"
    exit 1
  fi

  # Không source file cấu hình. Chỉ chấp nhận đúng một giá trị CHOICE=1..6.
  line="$(grep -E '^CHOICE="?([1-6])"?$' "$CONF_FILE" | tail -n1 || true)"
  value="${line#CHOICE=}"
  value="${value%\"}"
  value="${value#\"}"

  case "$value" in
    1|2|3|4|5|6) CHOICE="$value" ;;
    *)
      err "File cấu hình không hợp lệ."
      exit 1
      ;;
  esac
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

validate_carrier_db() {
  local asn owner
  declare -A seen=()
  for owner in TELECOM UNICOM MOBILE; do
    local -n arr="${owner}_ASNS"
    for asn in "${arr[@]}"; do
      [[ "$asn" =~ ^[0-9]+$ ]] || { err "ASN không hợp lệ trong $owner: $asn"; return 1; }
      if [[ -n "${seen[$asn]:-}" && "${seen[$asn]}" != "$owner" ]]; then
        err "ASN $asn bị gán cho cả ${seen[$asn]} và $owner. Dừng để tránh chặn nhầm carrier."
        return 1
      fi
      seen[$asn]="$owner"
    done
  done
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

  validate_carrier_db || return 1
  mapfile -t SELECTED_ASNS < <(printf '%s\n' "${SELECTED_ASNS[@]}" | sort -n -u)
}

fetch_prefixes() {
  local choice="$1"
  local tmpdir jsonfile asn
  local cache4 cache6 cacheok tmp4 tmp6 cache4_tmp cache6_tmp
  local failed=0 reused=0

  tmpdir="$(mktemp -d)"

  : >"$tmpdir/all4"
  : >"$tmpdir/all6"

  mkdir -p "$CACHE_DIR"
  build_asn_list "$choice"

  log "[+] Cập nhật IPv4 + IPv6 prefix từ RIPEstat..."

  for asn in "${SELECTED_ASNS[@]}"; do
    printf '    AS%s ... ' "$asn"

    jsonfile="$tmpdir/as${asn}.json"
    tmp4="$tmpdir/as${asn}.v4"
    tmp6="$tmpdir/as${asn}.v6"
    cache4="$CACHE_DIR/as${asn}.v4"
    cache6="$CACHE_DIR/as${asn}.v6"
    cacheok="$CACHE_DIR/as${asn}.ok"

    if curl --connect-timeout 8 --max-time 30 \
      --retry 2 --retry-delay 2 -fsSL \
      "https://stat.ripe.net/data/announced-prefixes/data.json?resource=AS${asn}&min_peers_seeing=1" \
      -o "$jsonfile" \
      && jq -e '.status == "ok" and (.data.prefixes | type == "array")' \
        "$jsonfile" >/dev/null 2>&1; then

      jq -r '.data.prefixes[]?.prefix' "$jsonfile" | grep -Fv ':' >"$tmp4" || true
      jq -r '.data.prefixes[]?.prefix' "$jsonfile" | grep -F ':'  >"$tmp6" || true

      # Cache commit có marker: bỏ marker cũ trước khi thay bất kỳ dữ liệu nào.
      # Nếu tiến trình chết giữa chừng, lần sau sẽ không dùng cache nửa cũ/nửa mới.
      rm -f "$cacheok"
      cache4_tmp="${cache4}.tmp.$$"
      cache6_tmp="${cache6}.tmp.$$"
      rm -f "$cache4_tmp" "$cache6_tmp"

      if cp -f "$tmp4" "$cache4_tmp" && cp -f "$tmp6" "$cache6_tmp"; then
        # Marker phải tiếp tục vắng trong toàn bộ cửa sổ commit.
        # fsync thư mục không cần thiết cho correctness runtime; marker là commit flag.
        rm -f "$cacheok"
        mv -f "$cache4_tmp" "$cache4"
        rm -f "$cacheok"
        mv -f "$cache6_tmp" "$cache6"
        rm -f "$cacheok"
        : >"$cacheok"
      else
        rm -f "$cache4_tmp" "$cache6_tmp" "$cacheok"
        rm -rf "$tmpdir"
        err "Không ghi được cache cho AS${asn}. Giữ nguyên firewall/IPSet cũ."
        return 1
      fi

      cat "$tmp4" >>"$tmpdir/all4"
      cat "$tmp6" >>"$tmpdir/all6"
      echo "OK"
      continue
    fi

    if [[ -f "$cacheok" && -f "$cache4" && -f "$cache6" ]]; then
      cat "$cache4" >>"$tmpdir/all4"
      cat "$cache6" >>"$tmpdir/all6"
      reused=$((reused + 1))
      echo "CACHE"
      continue
    fi

    failed=$((failed + 1))
    echo "LỖI"
  done

  sort -u "$tmpdir/all4" -o "$tmpdir/all4"
  sort -u "$tmpdir/all6" -o "$tmpdir/all6"

  PREFIX4_COUNT="$(grep -c . "$tmpdir/all4" || true)"
  PREFIX6_COUNT="$(grep -c . "$tmpdir/all6" || true)"

  if (( failed > 0 )); then
    err "Có $failed ASN chưa lấy được dữ liệu và chưa có cache."
    err "Giữ nguyên firewall/IPSet cũ."
    rm -rf "$tmpdir"
    return 1
  fi

  if (( PREFIX4_COUNT < 100 )); then
    err "IPv4 chỉ lấy được $PREFIX4_COUNT prefix. Không cập nhật firewall."
    rm -rf "$tmpdir"
    return 1
  fi

  if (( PREFIX6_COUNT < 1 )); then
    err "Không lấy được prefix IPv6. Không cập nhật để tránh báo chặn dual-stack giả."
    rm -rf "$tmpdir"
    return 1
  fi

  # Xác thực toàn bộ prefix bằng ipset tạm trước khi ghi file cập nhật.
  # Nếu RIPEstat/cache có một dòng lỗi, firewall cũ vẫn được giữ nguyên.
  local validate4="cncfw_validate4_$$" validate6="cncfw_validate6_$$"
  ipset destroy "$validate4" 2>/dev/null || true
  ipset destroy "$validate6" 2>/dev/null || true

  if ! ipset create "$validate4" hash:net family inet maxelem 262144; then
    rm -rf "$tmpdir"
    err "Không tạo được IPv4 validation IPSet. Giữ nguyên firewall/IPSet cũ."
    return 1
  fi
  if ! ipset create "$validate6" hash:net family inet6 maxelem 262144; then
    ipset destroy "$validate4" 2>/dev/null || true
    rm -rf "$tmpdir"
    err "Không tạo được IPv6 validation IPSet. Giữ nguyên firewall/IPSet cũ."
    return 1
  fi

  if ! awk -v s="$validate4" 'NF {print "add " s " " $0}' "$tmpdir/all4" | ipset restore      || ! awk -v s="$validate6" 'NF {print "add " s " " $0}' "$tmpdir/all6" | ipset restore; then
    ipset destroy "$validate4" 2>/dev/null || true
    ipset destroy "$validate6" 2>/dev/null || true
    rm -rf "$tmpdir"
    err "Dữ liệu prefix có dòng không hợp lệ. Giữ nguyên firewall/IPSet cũ."
    return 1
  fi
  ipset destroy "$validate4"
  ipset destroy "$validate6"

  # Stage cả hai file prefix; nếu một bước lỗi thì xóa cả hai staging file.
  if ! cp -f "$tmpdir/all4" "$PREFIX4_FILE" || ! cp -f "$tmpdir/all6" "$PREFIX6_FILE"; then
    rm -f "$PREFIX4_FILE" "$PREFIX6_FILE"
    rm -rf "$tmpdir"
    err "Không ghi được file prefix staging. Giữ nguyên firewall/IPSet cũ."
    return 1
  fi
  rm -rf "$tmpdir"

  if (( reused > 0 )); then
    warn "[!] Có $reused ASN dùng cache do RIPEstat/network lỗi tạm thời."
  fi

  log "[+] Tổng prefix IPv4: $PREFIX4_COUNT"
  log "[+] Tổng prefix IPv6: $PREFIX6_COUNT"
}

preflight_firewall() {
  # Kiểm tra backend trước khi thay đổi live IPSet.
  iptables -m set -h >/dev/null 2>&1 || {
    err "iptables không hỗ trợ match-set/ipset. Giữ nguyên firewall cũ."
    return 1
  }
  ip6tables -m set -h >/dev/null 2>&1 || {
    err "ip6tables không hỗ trợ match-set/ipset. Giữ nguyên firewall cũ."
    return 1
  }
}

next_pow2() {
  local n="$1" p=1
  (( n < 1 )) && n=1
  while (( p < n )); do p=$((p * 2)); done
  printf '%s\n' "$p"
}

ipset_sizing() {
  # Keep resident hash tables modest on 1C/1GB VPS while leaving headroom.
  # hashsize is only the initial hash size; maxelem is a safety ceiling.
  local count="$1" target max
  target=$(( (count + 3) / 4 ))
  (( target < 2048 )) && target=2048
  (( target > 32768 )) && target=32768
  IPSET_HASHSIZE="$(next_pow2 "$target")"

  max=$(( count * 2 + 1024 ))
  (( max < 65536 )) && max=65536
  (( max > 262144 )) && max=262144
  IPSET_MAXELEM="$(next_pow2 "$max")"
  (( IPSET_MAXELEM > 262144 )) && IPSET_MAXELEM=262144
}

update_ipsets_atomic() {
  # Tạo set tạm hoàn chỉnh trước. Firewall cũ vẫn hoạt động trong lúc nạp.
  ipset destroy "$SET4_NEW" 2>/dev/null || true
  ipset destroy "$SET6_NEW" 2>/dev/null || true

  local hash4 max4 hash6 max6
  ipset_sizing "$PREFIX4_COUNT"; hash4="$IPSET_HASHSIZE"; max4="$IPSET_MAXELEM"
  ipset_sizing "$PREFIX6_COUNT"; hash6="$IPSET_HASHSIZE"; max6="$IPSET_MAXELEM"

  ipset create "$SET4_NEW" hash:net family inet  hashsize "$hash4" maxelem "$max4"
  ipset create "$SET6_NEW" hash:net family inet6 hashsize "$hash6" maxelem "$max6"

  {
    while IFS= read -r net; do
      [[ -n "$net" ]] && printf 'add %s %s -exist\n' "$SET4_NEW" "$net"
    done <"$PREFIX4_FILE"
  } | ipset restore

  {
    while IFS= read -r net; do
      [[ -n "$net" ]] && printf 'add %s %s -exist\n' "$SET6_NEW" "$net"
    done <"$PREFIX6_FILE"
  } | ipset restore

  ipset create "$SET4" hash:net family inet  hashsize "$hash4" maxelem "$max4" -exist
  ipset create "$SET6" hash:net family inet6 hashsize "$hash6" maxelem "$max6" -exist

  # Hai swap không thể là một transaction kernel duy nhất. Nếu IPv6 swap lỗi
  # sau khi IPv4 đã swap, swap IPv4 ngược lại để tránh trạng thái mixed-generation.
  if ! ipset swap "$SET4_NEW" "$SET4"; then
    ipset destroy "$SET4_NEW" 2>/dev/null || true
    ipset destroy "$SET6_NEW" 2>/dev/null || true
    err "Không swap được IPv4 IPSet. Giữ nguyên firewall cũ."
    return 1
  fi

  if ! ipset swap "$SET6_NEW" "$SET6"; then
    warn "[!] IPv6 swap thất bại. Đang rollback IPv4..."
    if ! ipset swap "$SET4_NEW" "$SET4"; then
      err "ROLLBACK IPv4 thất bại. Cần kiểm tra firewall ngay."
      # Giữ các set tạm để có dữ liệu phục hồi thủ công, không destroy.
      return 1
    fi
    ipset destroy "$SET4_NEW" 2>/dev/null || true
    ipset destroy "$SET6_NEW" 2>/dev/null || true
    err "Không swap được IPv6 IPSet. IPv4 đã rollback về dữ liệu cũ."
    return 1
  fi

  ipset destroy "$SET4_NEW"
  ipset destroy "$SET6_NEW"

  rm -f "$PREFIX4_FILE" "$PREFIX6_FILE"
}

ensure_jump_once() {
  local fw="$1" parent="$2" child="$3"

  while "$fw" -C "$parent" -j "$child" >/dev/null 2>&1; do
    "$fw" -D "$parent" -j "$child"
  done

  "$fw" -I "$parent" 1 -j "$child"
}

apply_family_rules() {
  local fw="$1" setname="$2"

  "$fw" -N "$CHAIN_IN" 2>/dev/null || true
  "$fw" -F "$CHAIN_IN"
  "$fw" -A "$CHAIN_IN" -m set --match-set "$setname" src -j DROP

  "$fw" -N "$CHAIN_OUT" 2>/dev/null || true
  "$fw" -F "$CHAIN_OUT"
  "$fw" -A "$CHAIN_OUT" -m set --match-set "$setname" dst -j DROP

  "$fw" -N "$CHAIN_FWD" 2>/dev/null || true
  "$fw" -F "$CHAIN_FWD"
  "$fw" -A "$CHAIN_FWD" -m set --match-set "$setname" src -j DROP
  "$fw" -A "$CHAIN_FWD" -m set --match-set "$setname" dst -j DROP

  ensure_jump_once "$fw" INPUT   "$CHAIN_IN"
  ensure_jump_once "$fw" OUTPUT  "$CHAIN_OUT"
  ensure_jump_once "$fw" FORWARD "$CHAIN_FWD"
}

cleanup_legacy_ipv4() {
  # Các chain đời cũ trước CNCFW_*.
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

apply_firewall() {
  apply_family_rules iptables  "$SET4"
  apply_family_rules ip6tables "$SET6"

  cleanup_legacy_ipv4

  # Set IPv4 tên cũ của V2.x không còn được chain nào tham chiếu sau khi
  # CNCFW_* đã được flush và tạo lại.
  ipset destroy cncfw_block 2>/dev/null || true
  ipset destroy cn_ut_block 2>/dev/null || true
}

verify_family() {
  local fw="$1" setname="$2" label="$3"

  ipset list "$setname" >/dev/null 2>&1 || {
    err "Thiếu IPSet $label: $setname"
    return 1
  }

  "$fw" -C INPUT -j "$CHAIN_IN" >/dev/null 2>&1 || {
    err "$label thiếu jump INPUT -> $CHAIN_IN"
    return 1
  }
  "$fw" -C OUTPUT -j "$CHAIN_OUT" >/dev/null 2>&1 || {
    err "$label thiếu jump OUTPUT -> $CHAIN_OUT"
    return 1
  }
  "$fw" -C FORWARD -j "$CHAIN_FWD" >/dev/null 2>&1 || {
    err "$label thiếu jump FORWARD -> $CHAIN_FWD"
    return 1
  }

  "$fw" -C "$CHAIN_IN" -m set --match-set "$setname" src -j DROP >/dev/null 2>&1 || {
    err "$label thiếu DROP nguồn trong $CHAIN_IN"
    return 1
  }
  "$fw" -C "$CHAIN_OUT" -m set --match-set "$setname" dst -j DROP >/dev/null 2>&1 || {
    err "$label thiếu DROP đích trong $CHAIN_OUT"
    return 1
  }
  "$fw" -C "$CHAIN_FWD" -m set --match-set "$setname" src -j DROP >/dev/null 2>&1 || {
    err "$label thiếu DROP nguồn trong $CHAIN_FWD"
    return 1
  }
  "$fw" -C "$CHAIN_FWD" -m set --match-set "$setname" dst -j DROP >/dev/null 2>&1 || {
    err "$label thiếu DROP đích trong $CHAIN_FWD"
    return 1
  }
}

verify_firewall() {
  verify_family iptables  "$SET4" "IPv4"
  verify_family ip6tables "$SET6" "IPv6"
}

save_ipsets() {
  local tmp
  tmp="$(mktemp "${CONF_DIR}/ipset.rules.tmp.XXXXXX")" || {
    err "Không tạo được file tạm để lưu IPSet."
    return 1
  }

  if ! ipset save "$SET4" >"$tmp" || ! ipset save "$SET6" >>"$tmp"; then
    rm -f "$tmp"
    err "Không lưu được IPSet persistent."
    return 1
  fi

  if [[ ! -s "$tmp" ]]; then
    rm -f "$tmp"
    err "File IPSet persistent bị rỗng."
    return 1
  fi

  chmod 600 "$tmp"
  mv -f "$tmp" "$IPSET_SAVE"
}

save_persistence() {
  local ipset_bin
  mkdir -p "$CONF_DIR"
  save_ipsets

  ipset_bin="$(command -v ipset)" || {
    err "Không tìm thấy binary ipset."
    return 1
  }

  cat >"/etc/systemd/system/$RESTORE_SERVICE" <<EOF
[Unit]
Description=Restore China Carrier Firewall IPv4/IPv6 ipsets
DefaultDependencies=no
After=local-fs.target
Before=netfilter-persistent.service
ConditionPathIsReadable=$IPSET_SAVE

[Service]
Type=oneshot
ExecStart=/bin/sh -ec '$ipset_bin restore -exist < "$IPSET_SAVE"'
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

  mkdir -p /etc/systemd/system/netfilter-persistent.service.d

  cat >/etc/systemd/system/netfilter-persistent.service.d/cn-carrier-fw.conf <<EOF
[Unit]
Requires=$RESTORE_SERVICE
After=$RESTORE_SERVICE
EOF

  cat >"/etc/systemd/system/$UPDATE_SERVICE" <<EOF
[Unit]
Description=Update China Carrier Firewall IPv4/IPv6 prefixes
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
# Keep daily database refresh out of the dataplane on small 1C/1GB VPS.
# These affect only the update process, not packet forwarding.
Nice=19
IOSchedulingClass=idle
CPUWeight=10
ExecStart=$INSTALL_PATH --apply-saved
TimeoutStartSec=30min
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
  systemctl enable "$RESTORE_SERVICE" >/dev/null
  systemctl enable "$UPDATE_TIMER" >/dev/null
  systemctl enable netfilter-persistent.service >/dev/null 2>&1 || {
    err "Không enable được netfilter-persistent.service"
    return 1
  }

  # Chỉ kích hoạt timer sau khi firewall đã được lưu persistent thành công.
  # Tránh trạng thái cài đặt dở dang nhưng timer vẫn chạy.
  netfilter-persistent save >/dev/null

  [[ -s /etc/iptables/rules.v4 ]] || {
    err "Không thấy /etc/iptables/rules.v4 sau khi save."
    return 1
  }

  [[ -s /etc/iptables/rules.v6 ]] || {
    err "Không thấy /etc/iptables/rules.v6 sau khi save."
    return 1
  }

  systemctl is-enabled --quiet "$RESTORE_SERVICE" || {
    err "$RESTORE_SERVICE chưa được enable."
    return 1
  }
  systemctl is-enabled --quiet "$UPDATE_TIMER" || {
    err "$UPDATE_TIMER chưa được enable."
    return 1
  }
  systemctl is-enabled --quiet netfilter-persistent.service || {
    err "netfilter-persistent.service chưa được enable."
    return 1
  }

  systemctl is-active --quiet "$UPDATE_TIMER" || systemctl start "$UPDATE_TIMER"
}

apply_choice() {
  local choice="$1"

  rm -f "$PREFIX4_FILE" "$PREFIX6_FILE"

  fetch_prefixes "$choice"
  preflight_firewall
  update_ipsets_atomic
  apply_firewall
  verify_firewall
  # Persist the already-verified live firewall first. Commit CHOICE only after
  # persistence succeeds, so a failed save cannot advertise a new selection.
  save_persistence
  save_choice "$choice" || {
    err "Firewall đã lưu nhưng không ghi được cấu hình CHOICE."
    return 1
  }

  echo
  log "=================================================="
  log " HOÀN TẤT - IPv4 + IPv6"
  log " $(choice_description "$choice")"
  log " Prefix IPv4: $PREFIX4_COUNT"
  log " Prefix IPv6: $PREFIX6_COUNT"
  log " Protocol: ALL (TCP/UDP/ICMP/ICMPv6/khác)"
  log " INPUT + OUTPUT + FORWARD: BLOCK"
  log " Tự cập nhật: mỗi 24 giờ"
  log "=================================================="
}

remove_chain_family() {
  local fw="$1"

  while "$fw" -C INPUT -j "$CHAIN_IN" >/dev/null 2>&1; do
    "$fw" -D INPUT -j "$CHAIN_IN" || true
  done
  while "$fw" -C OUTPUT -j "$CHAIN_OUT" >/dev/null 2>&1; do
    "$fw" -D OUTPUT -j "$CHAIN_OUT" || true
  done
  while "$fw" -C FORWARD -j "$CHAIN_FWD" >/dev/null 2>&1; do
    "$fw" -D FORWARD -j "$CHAIN_FWD" || true
  done

  "$fw" -F "$CHAIN_IN" 2>/dev/null || true
  "$fw" -X "$CHAIN_IN" 2>/dev/null || true
  "$fw" -F "$CHAIN_OUT" 2>/dev/null || true
  "$fw" -X "$CHAIN_OUT" 2>/dev/null || true
  "$fw" -F "$CHAIN_FWD" 2>/dev/null || true
  "$fw" -X "$CHAIN_FWD" 2>/dev/null || true
}


download_latest_script() {
  local dest="$1"
  local token="${GITHUB_TOKEN:-}"

  if [[ -z "$token" && -s "$GITHUB_TOKEN_FILE" ]]; then
    token="$(tr -d '\r\n' < "$GITHUB_TOKEN_FILE")"
  fi

  if [[ -n "$token" ]]; then
    curl --connect-timeout 10 --max-time 60 --retry 2 --retry-delay 2 -fsSL \
      -H "Authorization: Bearer $token" \
      -H "Accept: application/vnd.github.raw+json" \
      "https://api.github.com/repos/${GITHUB_OWNER}/${GITHUB_REPO}/contents/${GITHUB_FILE}?ref=${GITHUB_BRANCH}" \
      -o "$dest"
  else
    curl --connect-timeout 10 --max-time 60 --retry 2 --retry-delay 2 -fsSL \
      "$RAW_URL" -o "$dest"
  fi
}

extract_version_from_file() {
  local file="$1"
  sed -n 's/^VERSION="\([^"]*\)".*/\1/p' "$file" | head -n1
}

self_update() {
  local tmp backup newver oldver
  tmp="$(mktemp)"
  backup="${INSTALL_PATH}.backup"
  oldver="$VERSION"

  log "[+] Kiểm tra bản cập nhật mới..."

  if ! download_latest_script "$tmp"; then
    rm -f "$tmp"
    err "Không tải được file cập nhật."
    if [[ ! -s "$GITHUB_TOKEN_FILE" && -z "${GITHUB_TOKEN:-}" ]]; then
      warn "Nếu repo GitHub là PRIVATE, hãy lưu token vào:"
      warn "  $GITHUB_TOKEN_FILE"
    fi
    return 1
  fi

  if [[ ! -s "$tmp" ]]; then
    rm -f "$tmp"
    err "File tải về rỗng."
    return 1
  fi

  if ! head -n1 "$tmp" | grep -q '^#!/usr/bin/env bash'; then
    rm -f "$tmp"
    err "File tải về không giống script cn-carrier-fw."
    return 1
  fi

  if ! grep -q '^APP="cn-carrier-fw"' "$tmp"; then
    rm -f "$tmp"
    err "Không tìm thấy marker APP trong bản tải về."
    return 1
  fi

  if ! bash -n "$tmp"; then
    rm -f "$tmp"
    err "Bản mới có lỗi cú pháp Bash. Không cập nhật."
    return 1
  fi

  newver="$(extract_version_from_file "$tmp")"
  [[ -n "$newver" ]] || newver="không rõ"

  echo
  echo "Bản hiện tại : $oldver"
  echo "Bản trên Git : $newver"
  echo

  if cmp -s "$tmp" "$INSTALL_PATH"; then
    rm -f "$tmp"
    log "[+] Bạn đang dùng đúng file mới nhất. Không cần cập nhật."
    return 0
  fi

  if [[ -f "$INSTALL_PATH" ]]; then
    cp -f "$INSTALL_PATH" "$backup"
    chmod 700 "$backup"
  else
    cp -f "${BASH_SOURCE[0]}" "$backup"
    chmod 700 "$backup"
  fi

  if ! install -m 700 "$tmp" "$INSTALL_PATH"; then
    rm -f "$tmp"
    err "Không thể thay file chương trình. Giữ nguyên bản cũ."
    cp -f "$backup" "$INSTALL_PATH" 2>/dev/null || true
    chmod 700 "$INSTALL_PATH" 2>/dev/null || true
    rm -f "$backup"
    return 1
  fi
  rm -f "$tmp"

  if ! bash -n "$INSTALL_PATH"; then
    err "Bản mới lỗi sau khi cài. Đang rollback..."
    cp -f "$backup" "$INSTALL_PATH"
    chmod 700 "$INSTALL_PATH"
    rm -f "$backup"
    return 1
  fi

  rm -f "$backup"
  systemctl daemon-reload >/dev/null 2>&1 || true

  log "[+] SELF-UPDATE HOÀN TẤT: $oldver -> $newver"
  log "[+] Firewall hiện tại được GIỮ NGUYÊN, không tải lại 19k/10k prefix."
  log "[+] Lần mở cn-carrier-fw tiếp theo sẽ chạy code mới."
  log "[+] Nếu muốn cập nhật prefix ngay, chọn mục 8."
  return 0
}

remove_all() {
  log "[+] Gỡ China Carrier Firewall IPv4 + IPv6..."

  remove_chain_family iptables
  remove_chain_family ip6tables
  cleanup_legacy_ipv4

  ipset destroy "$SET4_NEW" 2>/dev/null || true
  ipset destroy "$SET6_NEW" 2>/dev/null || true
  ipset destroy "$SET4" 2>/dev/null || true
  ipset destroy "$SET6" 2>/dev/null || true

  # Tên set các phiên bản cũ.
  ipset destroy cncfw_block 2>/dev/null || true
  ipset destroy cn_ut_block 2>/dev/null || true

  systemctl disable --now "$UPDATE_TIMER" >/dev/null 2>&1 || true
  systemctl disable --now "$RESTORE_SERVICE" >/dev/null 2>&1 || true

  rm -f \
    "/etc/systemd/system/$RESTORE_SERVICE" \
    "/etc/systemd/system/$UPDATE_SERVICE" \
    "/etc/systemd/system/$UPDATE_TIMER" \
    "/etc/systemd/system/netfilter-persistent.service.d/cn-carrier-fw.conf" \
    "$CONF_FILE" "$IPSET_SAVE" \
    "$PREFIX4_FILE" "$PREFIX6_FILE"

  rm -rf "$CACHE_DIR"

  systemctl daemon-reload
  netfilter-persistent save >/dev/null 2>&1 || true

  log "[+] Đã gỡ toàn bộ IPv4 + IPv6 rule do script tạo."
}

show_set_status() {
  local setname="$1" label="$2"

  echo "--- $label IPSet ---"
  if ipset list "$setname" >/dev/null 2>&1; then
    ipset list "$setname" | grep -E '^(Name:|Type:|Header:|Size in memory:|Number of entries:)'
  else
    echo "$setname: chưa tồn tại"
  fi
}

show_family_rules() {
  local fw="$1" label="$2"

  echo
  echo "--- $label INPUT ---"
  "$fw" -L "$CHAIN_IN" -n -v 2>/dev/null || true
  echo
  echo "--- $label OUTPUT ---"
  "$fw" -L "$CHAIN_OUT" -n -v 2>/dev/null || true
  echo
  echo "--- $label FORWARD ---"
  "$fw" -L "$CHAIN_FWD" -n -v 2>/dev/null || true
}


check_ip() {
  local ip="${1:-}"
  local setname family json asn_list prefix

  if [[ -z "$ip" ]]; then
    err "Thiếu IP. Ví dụ: cn-carrier-fw --check-ip 1.2.3.4"
    return 1
  fi

  # Chỉ nhận IP đơn, không nhận CIDR/hostname/chuỗi tùy ý.
  if [[ "$ip" == */* || "$ip" =~ [[:space:]] ]]; then
    err "IP không hợp lệ: $ip"
    return 1
  fi

  if [[ "$ip" == *:* ]]; then
    family="IPv6"
    # ip6tables dùng inet_pton; dùng Python nếu có để xác thực chính xác.
    if command -v python3 >/dev/null 2>&1; then
      python3 - "$ip" <<'PY' >/dev/null 2>&1 || { err "IPv6 không hợp lệ: $ip"; return 1; }
import ipaddress, sys
a = ipaddress.ip_address(sys.argv[1])
raise SystemExit(0 if a.version == 6 else 1)
PY
    fi
    setname="$SET6"
  else
    family="IPv4"
    if ! [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
      err "IPv4 không hợp lệ: $ip"
      return 1
    fi
    IFS=. read -r a b c d <<<"$ip"
    for octet in "$a" "$b" "$c" "$d"; do
      (( 10#$octet <= 255 )) || { err "IPv4 không hợp lệ: $ip"; return 1; }
    done
    setname="$SET4"
  fi

  echo "IP: $ip ($family)"
  if ipset test "$setname" "$ip" >/dev/null 2>&1; then
    echo "IPSet: BLOCKED ($setname)"
  else
    echo "IPSet: NOT BLOCKED ($setname)"
  fi

  echo "RIPEstat origin:"
  if ! json="$(curl --connect-timeout 5 --max-time 15 --retry 1 -fsSL \
      "https://stat.ripe.net/data/prefix-overview/data.json?resource=${ip}&min_peers_seeing=1" 2>/dev/null)"; then
    echo "Không tra được RIPEstat"
    return 0
  fi

  prefix="$(jq -r 'if .status=="ok" then (.data.resource // "?") else "?" end' <<<"$json" 2>/dev/null || echo "?")"
  asn_list="$(jq -r '
      if .status=="ok" then
        [(.data.asns // [])[] | "AS" + (.asn|tostring) + ":" + (.holder // "?")] | join(", ")
      else ""
      end
    ' <<<"$json" 2>/dev/null || true)"

  echo "prefix=$prefix ASN=${asn_list:-?}"
}

show_status() {
  echo "=================================================="
  echo " CHINA CARRIER FIREWALL - DUAL STACK ($VERSION)"
  echo "=================================================="

  if [[ -f "$CONF_FILE" ]]; then
    # shellcheck disable=SC1090
    source "$CONF_FILE"
    echo "Cấu hình: $(choice_description "${CHOICE:-0}")"
  else
    echo "Cấu hình: chưa lưu"
  fi

  echo
  show_set_status "$SET4" "IPv4"
  echo
  show_set_status "$SET6" "IPv6"

  show_family_rules iptables "IPv4"
  show_family_rules ip6tables "IPv6"

  echo
  echo "--- TIMER ---"
  systemctl list-timers "$UPDATE_TIMER" --no-pager 2>/dev/null || true
}

menu() {
  while true; do
    clear 2>/dev/null || true
    cat <<'EOF'
==================================================
      CHINA CARRIER FIREWALL - IPv4 + IPv6
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
  8) Cập nhật lại IPv4 + IPv6 prefix ngay
  9) Cập nhật chương trình từ GitHub
 10) Gỡ toàn bộ chặn IPv4 + IPv6

  0) Thoát

==================================================
EOF

    read -r -p "Nhập lựa chọn [0-10]: " choice

    case "$choice" in
      1|2|3|4|5|6)
        echo
        warn "Bạn chọn: $(choice_description "$choice")"
        warn "Sẽ chặn ALL protocol trên IPv4 + IPv6, INPUT + OUTPUT + FORWARD."
        warn "Nếu IP SSH hiện tại thuộc nhà mạng bị chặn, SSH có thể bị ngắt."
        read -r -p "Tiếp tục? [y/N]: " confirm

        if [[ "$confirm" =~ ^[Yy]$ ]]; then
          apply_choice "$choice"
        fi

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
        self_update || true
        read -r -p "Nhấn Enter để quay lại menu..." _
        ;;

      10)
        warn "Thao tác này sẽ gỡ toàn bộ IPv4 + IPv6 firewall do script tạo."
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
  mkdir -p "$CONF_DIR" "$CACHE_DIR"

  install_packages

  exec 9>"$LOCK_FILE"
  if ! flock -w 60 9; then
    err "Một tiến trình $APP khác vẫn đang chạy sau 60 giây. Hãy thử lại sau."
    exit 1
  fi

  install_self

  case "${1:-}" in
    --apply-saved)
      load_choice
      apply_choice "$CHOICE"
      ;;

    --status)
      show_status
      ;;

    --check-ip)
      check_ip "${2:-}"
      ;;

    --remove)
      remove_all
      ;;

    --help|-h)
      cat <<EOF
$APP $VERSION
  Không tham số      Mở menu
  --apply-saved      Cập nhật IPv4 + IPv6 và áp dụng cấu hình đã lưu
  --status           Xem trạng thái IPv4 + IPv6
  --check-ip IP      Kiểm tra IP có nằm trong bộ chặn + tra ASN
  --remove           Gỡ toàn bộ IPv4 + IPv6 rule
  Menu 9             Self-update code từ GitHub
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
