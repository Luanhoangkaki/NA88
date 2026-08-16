#!/bin/bash
set -euo pipefail

# China Mobile + China Unicom firewall blocker
# Blocks INPUT + OUTPUT for configured ISP ASNs using RIPEstat announced prefixes.
# China Telecom and other ISPs are not intentionally blocked.

if [ "$(id -u)" -ne 0 ]; then
  echo "ERROR: Please run as root."
  exit 1
fi

DIR="/etc/cn-isp-block"

echo "=========================================="
echo " China Mobile + China Unicom Firewall"
echo " INPUT + OUTPUT"
echo "=========================================="

export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y nftables curl jq
mkdir -p "$DIR"

cat >/usr/local/sbin/cn-isp-block-update <<'SCRIPT'
#!/bin/bash
set -euo pipefail

DIR="/etc/cn-isp-block"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$DIR"

# China Mobile + China Unicom ASN list.
# China Telecom is intentionally not included.
ASNS=(
  # China Mobile
  9808
  56040
  56041
  56042
  56044
  56046
  56047
  134810

  # China Unicom
  4837
  4808
  17621
  17622
  17623
  17816
  135061
)

V4="$TMP/v4.txt"
V6="$TMP/v6.txt"
: >"$V4"
: >"$V6"

echo "=========================================="
echo " Updating China Mobile + China Unicom"
echo "=========================================="

SUCCESS=0
FAILED=0

for ASN in "${ASNS[@]}"; do
  printf "AS%-8s " "$ASN"
  JSON="$TMP/as${ASN}.json"

  if curl -fsSL --retry 3 --retry-delay 2 \
      --connect-timeout 15 --max-time 60 \
      "https://stat.ripe.net/data/announced-prefixes/data.json?resource=AS${ASN}" \
      -o "$JSON"; then

    COUNT="$(jq -r '.data.prefixes[]?.prefix // empty' "$JSON" | wc -l)"
    echo "OK ($COUNT prefixes)"

    jq -r '.data.prefixes[]?.prefix // empty' "$JSON" |
    while read -r PREFIX; do
      [ -z "$PREFIX" ] && continue
      if [[ "$PREFIX" == *:* ]]; then
        echo "$PREFIX" >>"$V6"
      else
        echo "$PREFIX" >>"$V4"
      fi
    done

    SUCCESS=$((SUCCESS + 1))
  else
    echo "FAILED"
    FAILED=$((FAILED + 1))
  fi
done

sort -Vu "$V4" -o "$V4"
sort -Vu "$V6" -o "$V6"

V4COUNT="$(wc -l <"$V4")"
V6COUNT="$(wc -l <"$V6")"

echo "ASN success : $SUCCESS"
echo "ASN failed  : $FAILED"
echo "IPv4        : $V4COUNT"
echo "IPv6        : $V6COUNT"

# Never destroy the currently working firewall if the remote source fails.
if [ "$V4COUNT" -eq 0 ]; then
  echo "ERROR: No IPv4 prefixes received. Existing firewall was left unchanged."
  exit 1
fi

NFT="$TMP/cn-isp-block.nft"

{
cat <<'EOF'
table inet cn_isp_block {
    set blocked_v4 {
        type ipv4_addr
        flags interval
        auto-merge
        elements = {
EOF
awk '{printf "            %s,\n",$0}' "$V4"
cat <<'EOF'
        }
    }

    set blocked_v6 {
        type ipv6_addr
        flags interval
        auto-merge
        elements = {
EOF
awk '{printf "            %s,\n",$0}' "$V6"
cat <<'EOF'
        }
    }

    chain input {
        type filter hook input priority -10; policy accept;
        ip saddr @blocked_v4 counter drop
        ip6 saddr @blocked_v6 counter drop
    }

    chain output {
        type filter hook output priority -10; policy accept;
        ip daddr @blocked_v4 counter drop
        ip6 daddr @blocked_v6 counter drop
    }
}
EOF
} >"$NFT"

# Validate the new ruleset before replacing the active table.
nft -c -f "$NFT"

nft delete table inet cn_isp_block 2>/dev/null || true
nft -f "$NFT"

cp "$V4" "$DIR/blocked-v4.txt"
cp "$V6" "$DIR/blocked-v6.txt"
cp "$NFT" "$DIR/current.nft"
printf "%s\n" "${ASNS[@]}" >"$DIR/asns.txt"
date '+%Y-%m-%d %H:%M:%S %Z' >"$DIR/last-update.txt"

echo "=========================================="
echo " UPDATE COMPLETE"
echo " China Mobile : INPUT + OUTPUT BLOCKED"
echo " China Unicom : INPUT + OUTPUT BLOCKED"
echo " China Telecom / other ISPs: unchanged"
echo "=========================================="
SCRIPT

chmod +x /usr/local/sbin/cn-isp-block-update

cat >/usr/local/sbin/cn-isp-block-load <<'SCRIPT'
#!/bin/bash
set -e
FILE="/etc/cn-isp-block/current.nft"
[ -f "$FILE" ] || exit 0
nft delete table inet cn_isp_block 2>/dev/null || true
nft -f "$FILE"
SCRIPT
chmod +x /usr/local/sbin/cn-isp-block-load

cat >/usr/local/sbin/cn-isp-block-uninstall <<'SCRIPT'
#!/bin/bash
set -e
systemctl disable --now cn-isp-block-update.timer 2>/dev/null || true
systemctl disable --now cn-isp-block-load.service 2>/dev/null || true
nft delete table inet cn_isp_block 2>/dev/null || true
rm -f /etc/systemd/system/cn-isp-block-update.service
rm -f /etc/systemd/system/cn-isp-block-update.timer
rm -f /etc/systemd/system/cn-isp-block-load.service
rm -f /usr/local/sbin/cn-isp-block-update
rm -f /usr/local/sbin/cn-isp-block-load
rm -rf /etc/cn-isp-block
systemctl daemon-reload
echo "China ISP block removed."
echo "Optional: rm -f /usr/local/sbin/cn-isp-block-uninstall"
SCRIPT
chmod +x /usr/local/sbin/cn-isp-block-uninstall

cat >/etc/systemd/system/cn-isp-block-load.service <<'EOF'
[Unit]
Description=Load China Mobile and China Unicom firewall
After=network-pre.target
Before=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/cn-isp-block-load
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

cat >/etc/systemd/system/cn-isp-block-update.service <<'EOF'
[Unit]
Description=Update China Mobile and China Unicom IP blocklist
Wants=network-online.target
After=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/cn-isp-block-update
EOF

cat >/etc/systemd/system/cn-isp-block-update.timer <<'EOF'
[Unit]
Description=Daily China Mobile and China Unicom blocklist update

[Timer]
OnBootSec=10min
OnUnitActiveSec=24h
Persistent=true

[Install]
WantedBy=timers.target
EOF

# Remove obsolete timer name from an earlier version, if present.
systemctl disable --now cn-isp-block.timer 2>/dev/null || true
rm -f /etc/systemd/system/cn-isp-block.timer
rm -f /etc/systemd/system/cn-isp-block.service

systemctl daemon-reload
systemctl enable cn-isp-block-load.service
systemctl enable --now cn-isp-block-update.timer

/usr/local/sbin/cn-isp-block-update

echo
echo "=========================================="
echo " INSTALL COMPLETE"
echo "=========================================="
echo "Update : cn-isp-block-update"
echo "Status : nft list table inet cn_isp_block"
echo "Timer  : systemctl status cn-isp-block-update.timer"
echo "Remove : cn-isp-block-uninstall"
echo "=========================================="
