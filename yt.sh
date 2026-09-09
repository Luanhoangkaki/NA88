#!/usr/bin/env bash
set -Eeuo pipefail
VERSION="7.5.0-base"
BASE="/usr/local/lib/yt-v7"
SELF="/usr/local/bin/yt7"
die(){ echo "[ERROR] $*" >&2; exit 1; }
ok(){ echo "[OK] $*"; }
install_self(){
  [[ $EUID -eq 0 ]] || die "Hãy chạy bằng root."
  local srcdir; srcdir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  for f in yt.sh yt-main.sh yt-exit.sh; do [[ -f "$srcdir/$f" ]] || die "Thiếu $f"; done
  mkdir -p "$BASE"
  install -m755 "$srcdir/yt.sh" "$BASE/yt.sh"
  install -m755 "$srcdir/yt-main.sh" "$BASE/yt-main.sh"
  install -m755 "$srcdir/yt-exit.sh" "$BASE/yt-exit.sh"
  ln -sfn "$BASE/yt.sh" "$SELF"
  ok "Đã cài/cập nhật launcher yt7."
}
menu(){
  while true; do
    clear 2>/dev/null || true
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo " YT V7 BASE $VERSION"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "Role: $(cat /etc/yt-v7/role 2>/dev/null || echo NONE)"
    echo "1) MAIN"
    echo "2) EXIT"
    echo "3) Cài/Cập nhật launcher local"
    echo "0) Thoát"
    read -rp "Chọn: " x
    case "$x" in
      1) [[ -x "$BASE/yt-main.sh" ]] || die "Chạy: bash yt.sh install"; exec "$BASE/yt-main.sh" menu;;
      2) [[ -x "$BASE/yt-exit.sh" ]] || die "Chạy: bash yt.sh install"; exec "$BASE/yt-exit.sh" menu;;
      3) install_self; read -rp "Enter..." _;;
      0) exit 0;;
    esac
  done
}
case "${1:-}" in install) install_self;; version) echo "$VERSION";; *) menu;; esac
