#!/usr/bin/env bash
# China Carrier Firewall - Dual Stack
# Chặn China Telecom / China Unicom / China Mobile theo ASN prefix
# Debian 11/12/13 + Ubuntu 20.04/22.04/24.04 - IPv4 + IPv6
# Native nftables backend (modern systems); avoids iptables-nft/ipset incompatibility
#
# Chế độ:
#   cn-carrier-fw                -> menu tương tác
#   cn-carrier-fw --apply-saved -> cập nhật prefix và áp dụng cấu hình đã lưu
#   cn-carrier-fw --status      -> xem trạng thái
#   cn-carrier-fw --remove      -> gỡ toàn bộ rule do script tạo
#
set -Eeuo pipefail

APP="cn-carrier-fw"
VERSION="3.5.8-carrier-only-safe"
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
  if ! command -v apt-get >/dev/null 2>&1 || ! command -v dpkg >/dev/null 2>&1 || ! command -v systemctl >/dev/null 2>&1; then
    err "Chỉ hỗ trợ Debian/Ubuntu dùng apt + systemd."
    return 1
  fi
  local missing=0
  for c in curl jq nft flock; do command -v "$c" >/dev/null 2>&1 || missing=1; done
  if [[ "$missing" -eq 1 ]]; then
    log "[+] Cài gói cần thiết..."
    apt-get update -qq
    apt-get install -y -qq curl jq nftables util-linux >/dev/null
  fi
  modprobe nf_tables 2>/dev/null || true
  nft list tables >/dev/null 2>&1 || { err "Kernel/VPS không cho phép nftables."; return 1; }
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

sanitize_prefix_file() {
  local family="$1" infile="$2" outfile="$3" asn="$4"
  command -v python3 >/dev/null 2>&1 || { err "Thiếu python3 để kiểm tra prefix an toàn."; return 1; }
  python3 - "$family" "$infile" "$outfile" "$asn" <<'PYSAFE'
import ipaddress, sys
family, src, dst, asn = sys.argv[1:]
want = 4 if family == "4" else 6
seen=set(); rejected=[]
with open(src, encoding="utf-8", errors="replace") as f:
    for raw in f:
        token=raw.strip()
        if not token:
            continue
        try:
            net=ipaddress.ip_network(token, strict=True)
        except ValueError:
            rejected.append((token,"invalid/non-canonical")); continue
        if net.version != want:
            rejected.append((token,"wrong-family")); continue
        if net.prefixlen == 0:
            rejected.append((token,"default-route")); continue
        # BGP carrier blocklist must never contain local/special-use space.
        if (net.is_private or net.is_loopback or net.is_link_local or
            net.is_multicast or net.is_unspecified or net.is_reserved):
            rejected.append((token,"special/non-public")); continue
        seen.add(str(net))
with open(dst,"w",encoding="utf-8") as o:
    for x in sorted(seen, key=lambda z:(ipaddress.ip_network(z).network_address,
                                        ipaddress.ip_network(z).prefixlen)):
        o.write(x+"\n")
for token,why in rejected:
    print(f"[!] AS{asn}: loại prefix không an toàn {token} ({why})", file=sys.stderr)
PYSAFE
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

      jq -r '.data.prefixes[]?.prefix' "$jsonfile" | grep -Fv ':' >"${tmp4}.raw" || true
      jq -r '.data.prefixes[]?.prefix' "$jsonfile" | grep -F ':'  >"${tmp6}.raw" || true

      # Strict carrier-only safety gate. Only valid public CIDRs announced by
      # this selected ASN are allowed into cache/candidate. Default routes,
      # malformed/non-canonical CIDRs and special/local ranges are discarded.
      if ! sanitize_prefix_file 4 "${tmp4}.raw" "$tmp4" "$asn" ||          ! sanitize_prefix_file 6 "${tmp6}.raw" "$tmp6" "$asn"; then
        rm -rf "$tmpdir"
        err "Không kiểm tra an toàn được prefix AS${asn}. Giữ nguyên firewall cũ."
        return 1
      fi

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
      # Re-validate old cache too; never trust cache created by an older version.
      if ! sanitize_prefix_file 4 "$cache4" "$tmp4" "$asn" ||          ! sanitize_prefix_file 6 "$cache6" "$tmp6" "$asn"; then
        rm -rf "$tmpdir"
        err "Cache AS${asn} không qua được kiểm tra an toàn. Giữ nguyên firewall cũ."
        return 1
      fi
      cat "$tmp4" >>"$tmpdir/all4"
      cat "$tmp6" >>"$tmpdir/all6"
      reused=$((reused + 1))
      echo "CACHE"
      continue
    fi

    failed=$((failed + 1))
    echo "LỖI"
  done

  sort -u "$tmpdir/all4" -o "$tmpdir/all4"
  sort -u "$tmpdir/all6" -o "$tmpdir/all6"

  # Final invariant: no default route may ever reach the nft candidate, even if
  # a future fetch/cache path changes.
  if grep -Fxq '0.0.0.0/0' "$tmpdir/all4" 2>/dev/null || grep -Fxq '::/0' "$tmpdir/all6" 2>/dev/null; then
    err "Phát hiện default route nguy hiểm trong candidate. Hủy cập nhật."
    rm -rf "$tmpdir"
    return 1
  fi

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

  # Prefixes are syntactically validated when the candidate nft ruleset is built.
  # No temporary kernel set is allocated here, reducing peak RAM on 1C/1GB VPS.

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
  command -v nft >/dev/null 2>&1 || { err "Thiếu nftables."; return 1; }
  nft list tables >/dev/null 2>&1 || { err "nftables không hoạt động trên kernel/VPS này."; return 1; }
}

get_management_ip() {
  local ip=""
  # Ưu tiên IP nguồn của chính phiên SSH đang chạy.
  if [[ -n "${SSH_CONNECTION:-}" ]]; then
    ip="${SSH_CONNECTION%% *}"
  fi
  # Khi timer chạy không có SSH_CONNECTION, dùng IP quản trị đã ghi nhận ở lần
  # apply tương tác thành công gần nhất. Đây KHÔNG phải whitelist; nếu candidate
  # chứa IP này thì update bị hủy trước khi chạm firewall.
  if [[ -z "$ip" && -f "$CONF_FILE" ]]; then
    ip="$(sed -n 's/^MGMT_IP="\([^"]*\)"$/\1/p' "$CONF_FILE" | tail -n1)"
  fi
  printf '%s' "$ip"
}

validate_ip_literal() {
  local ip="$1"
  python3 - "$ip" <<'PYIP' >/dev/null 2>&1
import ipaddress, sys
try:
    ipaddress.ip_address(sys.argv[1])
except ValueError:
    raise SystemExit(1)
PYIP
}

candidate_contains_ip() {
  local ip="$1" prefix_file="$2"
  python3 - "$ip" "$prefix_file" <<'PYIP'
import ipaddress, sys
ip = ipaddress.ip_address(sys.argv[1])
with open(sys.argv[2], encoding='utf-8') as f:
    for line in f:
        p=line.strip()
        if not p:
            continue
        try:
            net=ipaddress.ip_network(p, strict=False)
        except ValueError:
            continue
        if ip.version == net.version and ip in net:
            print(p)
            raise SystemExit(0)
raise SystemExit(1)
PYIP
}

find_matching_selected_asn() {
  local ip="$1" asn f match
  for asn in "${SELECTED_ASNS[@]}"; do
    if [[ "$ip" == *:* ]]; then f="$CACHE_DIR/as${asn}.v6"; else f="$CACHE_DIR/as${asn}.v4"; fi
    [[ -f "$f" ]] || continue
    match="$(candidate_contains_ip "$ip" "$f" 2>/dev/null || true)"
    if [[ -n "$match" ]]; then
      printf 'AS%s %s\n' "$asn" "$match"
    fi
  done
}

preflight_management_lockout() {
  local ip prefix_file match details
  ip="$(get_management_ip)"
  if [[ -z "$ip" ]]; then
    warn "[!] Không có IP quản trị để anti-lockout (không chạy qua SSH và chưa có MGMT_IP lưu)."
    return 0
  fi
  if ! command -v python3 >/dev/null 2>&1 || ! validate_ip_literal "$ip"; then
    err "IP quản trị không hợp lệ: $ip"
    return 1
  fi
  if [[ "$ip" == *:* ]]; then prefix_file="$PREFIX6_FILE"; else prefix_file="$PREFIX4_FILE"; fi
  [[ -s "$prefix_file" ]] || { err "Thiếu candidate prefix để kiểm tra anti-lockout."; return 1; }

  match="$(candidate_contains_ip "$ip" "$prefix_file" 2>/dev/null || true)"
  if [[ -n "$match" ]]; then
    err "ANTI-LOCKOUT: candidate sẽ chặn IP quản trị $ip"
    err "Prefix gây match: $match"
    details="$(find_matching_selected_asn "$ip" || true)"
    [[ -n "$details" ]] && { err "Nguồn ASN trong lựa chọn hiện tại:"; printf '%s\n' "$details" >&2; }
    err "ĐÃ HỦY APPLY trước khi thay đổi nftables. SSH/firewall hiện tại được giữ nguyên."
    return 1
  fi
  log "[+] Anti-lockout: IP quản trị $ip không nằm trong candidate block."
  return 0
}

build_nft_candidate() {
  local out="$1"
  {
    echo 'table inet cncfw {'
    echo '  set block4 {'
    echo '    type ipv4_addr'
    echo '    flags interval'
    echo '    auto-merge'
    echo '    elements = {'
    awk 'NF {printf "      %s,\n", $0}' "$PREFIX4_FILE"
    echo '    }'
    echo '  }'
    echo '  set block6 {'
    echo '    type ipv6_addr'
    echo '    flags interval'
    echo '    auto-merge'
    echo '    elements = {'
    awk 'NF {printf "      %s,\n", $0}' "$PREFIX6_FILE"
    echo '    }'
    echo '  }'
    echo '  chain input {'
    echo '    type filter hook input priority -10; policy accept;'
    echo '    ip saddr @block4 counter drop'
    echo '    ip6 saddr @block6 counter drop'
    echo '  }'
    echo '  chain output {'
    echo '    type filter hook output priority -10; policy accept;'
    echo '    ip daddr @block4 counter drop'
    echo '    ip6 daddr @block6 counter drop'
    echo '  }'
    echo '  chain forward {'
    echo '    type filter hook forward priority -10; policy accept;'
    echo '    ip saddr @block4 counter drop'
    echo '    ip daddr @block4 counter drop'
    echo '    ip6 saddr @block6 counter drop'
    echo '    ip6 daddr @block6 counter drop'
    echo '  }'
    echo '}'
  } >"$out"
}

update_ipsets_atomic() {
  # Native nftables transaction: replace only our private table atomically.
  # IMPORTANT: never create an empty live table before candidate validation.
  local body batch had_table=0
  body="$(mktemp "${CONF_DIR}/nft.body.XXXXXX")" || return 1
  batch="$(mktemp "${CONF_DIR}/nft.batch.XXXXXX")" || { rm -f "$body"; return 1; }
  build_nft_candidate "$body"

  if nft list table inet cncfw >/dev/null 2>&1; then
    had_table=1
  fi

  if (( had_table )); then
    {
      echo 'delete table inet cncfw'
      cat "$body"
    } >"$batch"
  else
    cat "$body" >"$batch"
  fi

  # nft -c performs a dry-run syntax/semantic validation. Nothing live changes here.
  if ! nft -c -f "$batch"; then
    rm -f "$body" "$batch"
    err "Candidate nftables không hợp lệ. Giữ nguyên firewall cũ."
    return 1
  fi

  # One nft batch is one netlink transaction: either the private table is replaced
  # successfully or the old live ruleset remains in place.
  if ! nft -f "$batch"; then
    rm -f "$body" "$batch"
    err "Không apply được transaction nftables. Giữ nguyên firewall cũ."
    return 1
  fi

  if ! install -m 600 "$body" "$CONF_DIR/nftables.conf"; then
    rm -f "$body" "$batch"
    err "Live firewall đã apply nhưng không lưu được file persistence."
    return 1
  fi

  rm -f "$body" "$batch" "$PREFIX4_FILE" "$PREFIX6_FILE"
}

apply_firewall() { :; }

verify_firewall() {
  local in_dump out_dump fwd_dump set4_dump set6_dump
  nft list table inet cncfw >/dev/null 2>&1 || { err "Thiếu table inet cncfw"; return 1; }
  nft list set inet cncfw block4 >/dev/null 2>&1 || { err "Thiếu IPv4 set block4"; return 1; }
  nft list set inet cncfw block6 >/dev/null 2>&1 || { err "Thiếu IPv6 set block6"; return 1; }

  in_dump="$(nft list chain inet cncfw input 2>/dev/null)" || { err "Thiếu chain input"; return 1; }
  out_dump="$(nft list chain inet cncfw output 2>/dev/null)" || { err "Thiếu chain output"; return 1; }
  fwd_dump="$(nft list chain inet cncfw forward 2>/dev/null)" || { err "Thiếu chain forward"; return 1; }

  grep -q 'hook input' <<<"$in_dump" || { err "Chain input không gắn hook input"; return 1; }
  grep -q 'ip saddr @block4.*drop' <<<"$in_dump" || { err "Thiếu IPv4 rule trong INPUT"; return 1; }
  grep -q 'ip6 saddr @block6.*drop' <<<"$in_dump" || { err "Thiếu IPv6 rule trong INPUT"; return 1; }

  grep -q 'hook output' <<<"$out_dump" || { err "Chain output không gắn hook output"; return 1; }
  grep -q 'ip daddr @block4.*drop' <<<"$out_dump" || { err "Thiếu IPv4 rule trong OUTPUT"; return 1; }
  grep -q 'ip6 daddr @block6.*drop' <<<"$out_dump" || { err "Thiếu IPv6 rule trong OUTPUT"; return 1; }

  grep -q 'hook forward' <<<"$fwd_dump" || { err "Chain forward không gắn hook forward"; return 1; }
  grep -q 'ip saddr @block4.*drop' <<<"$fwd_dump" || { err "Thiếu IPv4 source rule trong FORWARD"; return 1; }
  grep -q 'ip daddr @block4.*drop' <<<"$fwd_dump" || { err "Thiếu IPv4 destination rule trong FORWARD"; return 1; }
  grep -q 'ip6 saddr @block6.*drop' <<<"$fwd_dump" || { err "Thiếu IPv6 source rule trong FORWARD"; return 1; }
  grep -q 'ip6 daddr @block6.*drop' <<<"$fwd_dump" || { err "Thiếu IPv6 destination rule trong FORWARD"; return 1; }

  # Capture the complete set output before grep. With set -o pipefail, using
  # `nft ... | grep -q` on a large set can make nft receive SIGPIPE after grep
  # finds the first match, falsely making the pipeline fail and reporting an
  # actually populated set as empty.
  set4_dump="$(nft list set inet cncfw block4 2>/dev/null)" || { err "Không đọc được IPv4 set block4"; return 1; }
  set6_dump="$(nft list set inet cncfw block6 2>/dev/null)" || { err "Không đọc được IPv6 set block6"; return 1; }
  grep -q 'elements = {' <<<"$set4_dump" || { err "IPv4 set rỗng"; return 1; }
  grep -q 'elements = {' <<<"$set6_dump" || { err "IPv6 set rỗng"; return 1; }
}

cleanup_legacy_cncfw() {
  # Best-effort migration cleanup only. Never switch iptables backend and never
  # flush global firewall tables. If an old xtables chain is incompatible, leave
  # it untouched rather than risking unrelated VPS rules.
  local fw
  for fw in iptables ip6tables; do
    command -v "$fw" >/dev/null 2>&1 || continue
    if "$fw" -S >/dev/null 2>&1; then
      remove_chain_family "$fw" || true
    fi
  done

  if command -v ipset >/dev/null 2>&1; then
    for oldset in cncfw_block4 cncfw_block4_new cncfw_block6 cncfw_block6_new cncfw_block cn_ut_block; do
      ipset destroy "$oldset" >/dev/null 2>&1 || true
    done
  fi
}


save_persistence() {
  local nft_bin
  mkdir -p "$CONF_DIR"
  [[ -s "$CONF_DIR/nftables.conf" ]] || { err "Thiếu nftables.conf"; return 1; }
  nft_bin="$(command -v nft)" || { err "Không tìm thấy nft"; return 1; }
  [[ -x "$nft_bin" ]] || { err "nft không executable: $nft_bin"; return 1; }

  # Restore helper builds ONE nft transaction. If cncfw already exists, deletion
  # and recreation happen in the same netlink batch, so restarting the service
  # does not create a delete->load gap.
  cat >"$CONF_DIR/restore-nft.sh" <<EOF
#!/usr/bin/env bash
set -Eeuo pipefail
NFT_BIN="$nft_bin"
CONF_FILE="$CONF_DIR/nftables.conf"
TMP=\$(mktemp /run/cncfw-restore.XXXXXX)
trap 'rm -f "\$TMP"' EXIT
[[ -s "\$CONF_FILE" ]] || exit 1
if "\$NFT_BIN" list table inet cncfw >/dev/null 2>&1; then
  { echo 'delete table inet cncfw'; cat "\$CONF_FILE"; } >"\$TMP"
else
  cat "\$CONF_FILE" >"\$TMP"
fi
"\$NFT_BIN" -c -f "\$TMP"
"\$NFT_BIN" -f "\$TMP"
"\$NFT_BIN" list table inet cncfw >/dev/null
EOF
  chmod 700 "$CONF_DIR/restore-nft.sh"

  cat >"/etc/systemd/system/$RESTORE_SERVICE" <<EOF
[Unit]
Description=Restore China Carrier Firewall nftables table atomically
DefaultDependencies=no
After=local-fs.target
Before=network-pre.target

[Service]
Type=oneshot
ExecStart=$CONF_DIR/restore-nft.sh
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
  systemctl is-enabled --quiet "$RESTORE_SERVICE" || { err "Không enable được restore service"; return 1; }
  systemctl is-enabled --quiet "$UPDATE_TIMER" || { err "Không enable được update timer"; return 1; }
  systemctl is-active --quiet "$UPDATE_TIMER" || systemctl start "$UPDATE_TIMER"
  systemctl is-active --quiet "$UPDATE_TIMER" || { err "Update timer không chạy"; return 1; }
}

apply_choice() {
  local choice="$1"
  local staged_choice old_live old_persist old_config had_live=0 had_persist=0 had_config=0
  local systemd_backup restore_helper_backup current_mgmt_ip
  local restore_enabled restore_active update_enabled update_active timer_enabled timer_active

  rm -f "$PREFIX4_FILE" "$PREFIX6_FILE"
  mkdir -p "$CONF_DIR"

  # Prepare the config commit BEFORE touching the live firewall. The final mv is
  # same-filesystem and atomic; this avoids late disk/allocation work after apply.
  staged_choice="$(mktemp "${CONF_DIR}/config.stage.XXXXXX")" || return 1
  printf 'CHOICE="%s"\n' "$choice" >"$staged_choice" || { rm -f "$staged_choice"; return 1; }
  current_mgmt_ip="$(get_management_ip)"
  if [[ -n "$current_mgmt_ip" ]] && command -v python3 >/dev/null 2>&1 && validate_ip_literal "$current_mgmt_ip"; then
    printf 'MGMT_IP="%s"\n' "$current_mgmt_ip" >>"$staged_choice" || { rm -f "$staged_choice"; return 1; }
  fi
  chmod 600 "$staged_choice" || { rm -f "$staged_choice"; return 1; }

  # Snapshots are used only if a post-apply commit step fails.
  old_live="$(mktemp "${CONF_DIR}/nft.oldlive.XXXXXX")" || { rm -f "$staged_choice"; return 1; }
  old_persist="$(mktemp "${CONF_DIR}/nft.oldpersist.XXXXXX")" || { rm -f "$staged_choice" "$old_live"; return 1; }
  old_config="$(mktemp "${CONF_DIR}/config.old.XXXXXX")" || { rm -f "$staged_choice" "$old_live" "$old_persist"; return 1; }

  if nft list table inet cncfw >"$old_live" 2>/dev/null; then had_live=1; else : >"$old_live"; fi
  if [[ -s "$CONF_DIR/nftables.conf" ]]; then cp -f "$CONF_DIR/nftables.conf" "$old_persist"; had_persist=1; else : >"$old_persist"; fi
  if [[ -f "$CONF_FILE" ]]; then cp -f "$CONF_FILE" "$old_config"; had_config=1; else : >"$old_config"; fi

  # Snapshot persistence helpers + systemd unit files and their runtime states.
  # save_persistence() mutates these after the live firewall is already applied,
  # so a later failure must be able to restore them too.
  systemd_backup="$(mktemp -d "${CONF_DIR}/systemd.old.XXXXXX")" || {
    rm -f "$staged_choice" "$old_live" "$old_persist" "$old_config"
    [[ -n "${systemd_backup:-}" ]] && rm -rf "$systemd_backup" || true
    return 1
  }
  restore_helper_backup="$systemd_backup/restore-nft.sh"
  for unit in "$RESTORE_SERVICE" "$UPDATE_SERVICE" "$UPDATE_TIMER"; do
    if [[ -f "/etc/systemd/system/$unit" ]]; then
      cp -a "/etc/systemd/system/$unit" "$systemd_backup/$unit"
      : >"$systemd_backup/$unit.existed"
    fi
  done
  if [[ -f "$CONF_DIR/restore-nft.sh" ]]; then
    cp -a "$CONF_DIR/restore-nft.sh" "$restore_helper_backup"
    : >"$systemd_backup/restore-helper.existed"
  fi

  restore_enabled="$(systemctl is-enabled "$RESTORE_SERVICE" 2>/dev/null || true)"
  restore_active="$(systemctl is-active "$RESTORE_SERVICE" 2>/dev/null || true)"
  update_enabled="$(systemctl is-enabled "$UPDATE_SERVICE" 2>/dev/null || true)"
  update_active="$(systemctl is-active "$UPDATE_SERVICE" 2>/dev/null || true)"
  timer_enabled="$(systemctl is-enabled "$UPDATE_TIMER" 2>/dev/null || true)"
  timer_active="$(systemctl is-active "$UPDATE_TIMER" 2>/dev/null || true)"

  rollback_apply() {
    local rb
    warn "[!] Commit chưa hoàn tất; đang rollback firewall/cấu hình cũ..."
    rb="$(mktemp "${CONF_DIR}/nft.rollback.XXXXXX")" || return 1
    if nft list table inet cncfw >/dev/null 2>&1; then echo 'delete table inet cncfw' >"$rb"; fi
    if (( had_live )); then cat "$old_live" >>"$rb"; fi
    if [[ -s "$rb" ]]; then nft -c -f "$rb" >/dev/null 2>&1 && nft -f "$rb" >/dev/null 2>&1 || warn "[!] Rollback live nftables thất bại; cần kiểm tra thủ công."; fi
    rm -f "$rb"
    if (( had_persist )); then install -m 600 "$old_persist" "$CONF_DIR/nftables.conf" || true; else rm -f "$CONF_DIR/nftables.conf"; fi
    if (( had_config )); then install -m 600 "$old_config" "$CONF_FILE" || true; else rm -f "$CONF_FILE"; fi

    # Restore helper/unit files exactly to their pre-apply presence/content.
    if [[ -f "$systemd_backup/restore-helper.existed" ]]; then
      cp -a "$restore_helper_backup" "$CONF_DIR/restore-nft.sh" 2>/dev/null || true
    else
      rm -f "$CONF_DIR/restore-nft.sh"
    fi
    for unit in "$RESTORE_SERVICE" "$UPDATE_SERVICE" "$UPDATE_TIMER"; do
      if [[ -f "$systemd_backup/$unit.existed" ]]; then
        cp -a "$systemd_backup/$unit" "/etc/systemd/system/$unit" 2>/dev/null || true
      else
        rm -f "/etc/systemd/system/$unit"
      fi
    done
    systemctl daemon-reload >/dev/null 2>&1 || true

    # Restore enablement. 'static'/'indirect' are not changed; only states that
    # were explicitly enabled/disabled before this transaction are replayed.
    case "$restore_enabled" in enabled) systemctl enable "$RESTORE_SERVICE" >/dev/null 2>&1 || true ;; disabled) systemctl disable "$RESTORE_SERVICE" >/dev/null 2>&1 || true ;; esac
    case "$update_enabled"  in enabled) systemctl enable "$UPDATE_SERVICE"  >/dev/null 2>&1 || true ;; disabled) systemctl disable "$UPDATE_SERVICE"  >/dev/null 2>&1 || true ;; esac
    case "$timer_enabled"   in enabled) systemctl enable "$UPDATE_TIMER"    >/dev/null 2>&1 || true ;; disabled) systemctl disable "$UPDATE_TIMER"    >/dev/null 2>&1 || true ;; esac

    # Restore active state without leaving a newly-created timer/service running.
    case "$timer_active" in active) systemctl start "$UPDATE_TIMER" >/dev/null 2>&1 || true ;; *) systemctl stop "$UPDATE_TIMER" >/dev/null 2>&1 || true ;; esac
    case "$restore_active" in active) systemctl start "$RESTORE_SERVICE" >/dev/null 2>&1 || true ;; *) systemctl stop "$RESTORE_SERVICE" >/dev/null 2>&1 || true ;; esac
    # UPDATE_SERVICE is oneshot and normally inactive; do not re-run a previous
    # update job during rollback. If it was not active, make sure it stays stopped.
    [[ "$update_active" == "active" ]] || systemctl stop "$UPDATE_SERVICE" >/dev/null 2>&1 || true
  }

  if ! fetch_prefixes "$choice" || ! preflight_firewall || ! preflight_management_lockout; then
    rm -f "$staged_choice" "$old_live" "$old_persist" "$old_config"
    [[ -n "${systemd_backup:-}" ]] && rm -rf "$systemd_backup" || true
    return 1
  fi

  # update_ipsets_atomic can already have changed the live table before a later
  # local persistence write fails, so any failure from this point must rollback.
  if ! update_ipsets_atomic; then
    rollback_apply
    rm -f "$staged_choice" "$old_live" "$old_persist" "$old_config"
    [[ -n "${systemd_backup:-}" ]] && rm -rf "$systemd_backup" || true
    return 1
  fi
  if ! verify_firewall; then
    rollback_apply
    rm -f "$staged_choice" "$old_live" "$old_persist" "$old_config"
    [[ -n "${systemd_backup:-}" ]] && rm -rf "$systemd_backup" || true
    return 1
  fi

  if ! save_persistence; then
    rollback_apply
    rm -f "$staged_choice" "$old_live" "$old_persist" "$old_config"
    [[ -n "${systemd_backup:-}" ]] && rm -rf "$systemd_backup" || true
    return 1
  fi

  # Final config commit. If even this atomic rename fails, restore the old state.
  if ! mv -f "$staged_choice" "$CONF_FILE"; then
    err "Không commit được CHOICE; rollback để tránh lệch trạng thái."
    rollback_apply
    rm -f "$staged_choice" "$old_live" "$old_persist" "$old_config"
    [[ -n "${systemd_backup:-}" ]] && rm -rf "$systemd_backup" || true
    return 1
  fi

  cleanup_legacy_cncfw
  rm -f "$old_live" "$old_persist" "$old_config"
  rm -rf "$systemd_backup"

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
  nft delete table inet cncfw 2>/dev/null || true
  cleanup_legacy_cncfw || true
  systemctl disable --now "$UPDATE_TIMER" >/dev/null 2>&1 || true
  systemctl disable --now "$RESTORE_SERVICE" >/dev/null 2>&1 || true
  rm -f "/etc/systemd/system/$RESTORE_SERVICE" "/etc/systemd/system/$UPDATE_SERVICE" "/etc/systemd/system/$UPDATE_TIMER" \
    "$CONF_FILE" "$CONF_DIR/nftables.conf" "$PREFIX4_FILE" "$PREFIX6_FILE"
  rm -rf "$CACHE_DIR"
  systemctl daemon-reload
  log "[+] Đã gỡ toàn bộ rule do script tạo."
}

show_set_status() {
  local setname="$1" label="$2"
  echo "--- $label nft set ---"
  nft list set inet cncfw "$setname" 2>/dev/null | grep -E 'elements =|counter' || echo "$setname: chưa tồn tại"
}
show_family_rules() {
  echo
  echo "--- nftables cncfw ---"
  nft list table inet cncfw 2>/dev/null || true
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
  # For interval/CIDR sets, verify membership against the live nft set dump.
  # This is a manual diagnostic path only; it is NOT used on packet processing.
  if command -v python3 >/dev/null 2>&1 && nft list set inet cncfw "$setname" >/dev/null 2>&1; then
    if nft list set inet cncfw "$setname" 2>/dev/null | python3 -c '
import ipaddress, re, sys
ip = ipaddress.ip_address(sys.argv[1])
text = sys.stdin.read()
m = re.search(r"elements\s*=\s*\{(.*?)\}", text, re.S)
if not m:
    raise SystemExit(1)
for raw in m.group(1).split(","):
    token = raw.strip().split()[0] if raw.strip() else ""
    if not token:
        continue
    try:
        if "-" in token:
            a, b = map(str.strip, token.split("-", 1))
            if ipaddress.ip_address(a) <= ip <= ipaddress.ip_address(b):
                raise SystemExit(0)
        elif ip in ipaddress.ip_network(token, strict=False):
            raise SystemExit(0)
    except ValueError:
        pass
raise SystemExit(1)
' "$ip"; then
      echo "nft set: BLOCKED ($setname)"
    else
      echo "nft set: NOT BLOCKED ($setname)"
    fi
  else
    # Fallback for minimal systems. nft itself performs the live set lookup.
    if nft get element inet cncfw "$setname" "{ $ip }" >/dev/null 2>&1; then
      echo "nft set: BLOCKED ($setname)"
    else
      echo "nft set: NOT BLOCKED ($setname)"
    fi
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
    local saved_line saved_choice
    saved_line="$(grep -E '^CHOICE="?([1-6])"?$' "$CONF_FILE" | tail -n1 || true)"
    saved_choice="${saved_line#CHOICE=}"; saved_choice="${saved_choice%\"}"; saved_choice="${saved_choice#\"}"
    echo "Cấu hình: $(choice_description "${saved_choice:-0}")"
  else
    echo "Cấu hình: chưa lưu"
  fi

  echo
  show_set_status "block4" "IPv4"
  echo
  show_set_status "block6" "IPv6"

  show_family_rules

  echo
  echo "--- TIMER ---"
  systemctl list-timers "$UPDATE_TIMER" --no-pager 2>/dev/null || true
}

dry_run_choice() {
  local choice="$1"
  case "$choice" in 1|2|3|4|5|6) ;; *) err "Dry-run cần lựa chọn 1..6"; return 1 ;; esac
  rm -f "$PREFIX4_FILE" "$PREFIX6_FILE"
  log "[+] DRY-RUN: $(choice_description "$choice")"
  log "[+] Chỉ tải/xây candidate và kiểm tra anti-lockout; KHÔNG thay firewall."
  if fetch_prefixes "$choice" && preflight_firewall && preflight_management_lockout; then
    log "[+] DRY-RUN PASS: candidate không chặn IP quản trị hiện tại."
    rm -f "$PREFIX4_FILE" "$PREFIX6_FILE"
    return 0
  fi
  rm -f "$PREFIX4_FILE" "$PREFIX6_FILE"
  return 1
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
        warn "Script sẽ kiểm tra anti-lockout trước khi apply; nếu IP SSH bị candidate bắt nhầm, thao tác sẽ tự hủy."
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

    --dry-run)
      dry_run_choice "${2:-}"
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
  --dry-run N        Kiểm tra lựa chọn 1..6 + anti-lockout, KHÔNG apply firewall
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
