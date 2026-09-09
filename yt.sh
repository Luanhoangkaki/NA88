#!/usr/bin/env bash
set -Eeuo pipefail

VERSION="6.8.0"
OWNER="${YT_REPO_OWNER:-Luanhoangkaki}"
REPO="${YT_REPO_NAME:-NA88}"
REF="${YT_REPO_REF:-main}"

BASE="/usr/local/lib/yt-manager"
CONF="/etc/yt-manager"
GH_ENV="$CONF/github.env"
SELF="/usr/local/bin/yt"

GREEN='\033[32m'
YELLOW='\033[33m'
RED='\033[31m'
CYAN='\033[36m'
RESET='\033[0m'

ok(){ echo -e "${GREEN}[OK]${RESET} $*"; }
info(){ echo -e "${CYAN}[INFO]${RESET} $*"; }
warn(){ echo -e "${YELLOW}[WARN]${RESET} $*"; }
die(){ echo -e "${RED}[ERROR]${RESET} $*" >&2; exit 1; }

need_root(){
  [[ ${EUID:-$(id -u)} -eq 0 ]] || die "Hãy chạy bằng root."
}


apt_retry(){
  local max_wait=600 waited=0 rc out
  while true; do
    out="$("$@" 2>&1)" && { printf '%s\n' "$out"; return 0; }
    rc=$?

    if grep -Eqi 'Could not get lock|Unable to acquire the dpkg frontend lock|is another process using it|Could not open lock file|frontend lock was locked by another process|locked by another process|Resource temporarily unavailable' <<<"$out"; then
      (( waited == 0 )) && warn "APT đang bận. Đang chờ tự động..."
      (( waited < max_wait )) || {
        printf '%s\n' "$out" >&2
        die "APT vẫn bị khóa sau ${max_wait}s."
      }
      sleep 5
      waited=$((waited+5))
      continue
    fi

    printf '%s\n' "$out" >&2
    return "$rc"
  done
}

install_deps(){
  command -v curl >/dev/null 2>&1 && command -v bash >/dev/null 2>&1 && return 0
  command -v apt-get >/dev/null 2>&1 || die "YT Manager chỉ hỗ trợ Debian/Ubuntu dùng apt."

  export DEBIAN_FRONTEND=noninteractive
  apt_retry dpkg --configure -a || die "dpkg --configure -a thất bại."
  apt_retry apt-get update || die "apt-get update thất bại."
  apt_retry apt-get install -y curl ca-certificates bash procps psmisc \
    || die "Không cài được dependency YT Manager."
}

load_token(){
  if [[ -z "${GH_TOKEN:-}" && -f "$GH_ENV" ]]; then
    # shellcheck disable=SC1090
    source "$GH_ENV"
  fi
}

save_token(){
  need_root
  local tok="${1:-${GH_TOKEN:-}}"

  if [[ -z "$tok" ]]; then
    read -rsp "GitHub token: " tok
    echo
  fi

  [[ -n "$tok" ]] || die "Token trống."

  mkdir -p "$CONF"
  chmod 700 "$CONF"
  printf "GH_TOKEN='%s'\n" "${tok//\'/}" >"$GH_ENV"
  chmod 600 "$GH_ENV"

  GH_TOKEN="$tok"
  export GH_TOKEN
  ok "Đã lưu GitHub token (chmod 600)."
}

delete_token(){
  need_root
  rm -f "$GH_ENV"
  unset GH_TOKEN || true
  ok "Đã xóa GitHub token khỏi VPS."
}

ensure_token(){
  load_token
  if [[ -z "${GH_TOKEN:-}" ]]; then
    echo "Repo GitHub đang dùng chế độ Private."
    save_token
  fi
}

gh_raw(){
  local path="$1"
  local out="$2"

  ensure_token

  curl -4fsSL --retry 3 --connect-timeout 10 \
    -H "Authorization: Bearer $GH_TOKEN" \
    -H "Accept: application/vnd.github.raw+json" \
    "https://api.github.com/repos/${OWNER}/${REPO}/contents/${path}?ref=${REF}" \
    -o "$out"
}

install_self(){
  need_root
  mkdir -p "$BASE" "$CONF"
  chmod 755 "$BASE"
  chmod 700 "$CONF"

  # Khi chạy từ file thật, cài chính file đó.
  if [[ "${BASH_SOURCE[0]}" != "$SELF" && -f "${BASH_SOURCE[0]}" ]]; then
    install -m 755 "${BASH_SOURCE[0]}" "$SELF"
    return 0
  fi

  # Khi chạy lần đầu bằng bash <(curl ...), BASH_SOURCE thường là /dev/fd/*
  # và không phải regular file. Tải lại yt.sh bằng token để lệnh "yt" tồn tại
  # sau khi bootstrap kết thúc.
  if [[ ! -x "$SELF" && -n "${GH_TOKEN:-}" ]]; then
    local tmp="/tmp/yt-bootstrap.$$"
    curl -4fsSL --retry 3 --connect-timeout 10 \
      -H "Authorization: Bearer $GH_TOKEN" \
      -H "Accept: application/vnd.github.raw+json" \
      "https://api.github.com/repos/${OWNER}/${REPO}/contents/yt.sh?ref=${REF}" \
      -o "$tmp" || { rm -f "$tmp"; die "Không thể cài /usr/local/bin/yt."; }

    bash -n "$tmp" || { rm -f "$tmp"; die "yt.sh trên Git lỗi cú pháp."; }
    install -m 755 "$tmp" "$SELF"
    rm -f "$tmp"
  fi
}

update_role(){
  local role="$1"
  local tmp="/tmp/yt-${role}.$$"

  gh_raw "yt-${role}.sh" "$tmp"
  bash -n "$tmp" || {
    rm -f "$tmp"
    die "yt-${role}.sh trên Git bị lỗi cú pháp. Không cập nhật."
  }

  install -m 755 "$tmp" "$BASE/yt-${role}.sh"
  ln -sfn "$BASE/yt-${role}.sh" "/usr/local/bin/yt-${role}"
  rm -f "$tmp"
}

ensure_role(){
  local role="$1"
  [[ -x "$BASE/yt-${role}.sh" ]] || update_role "$role"
  ln -sfn "$BASE/yt-${role}.sh" "/usr/local/bin/yt-${role}"
}

update_all(){
  need_root

  local d
  d="$(mktemp -d /tmp/yt-update.XXXXXX)"
  trap 'rm -rf "$d"' RETURN

  info "Tải bản cập nhật..."
  gh_raw "yt.sh" "$d/yt.sh"
  gh_raw "yt-main.sh" "$d/yt-main.sh"
  gh_raw "yt-exit.sh" "$d/yt-exit.sh"

  bash -n "$d/yt.sh" || die "yt.sh mới lỗi cú pháp."
  bash -n "$d/yt-main.sh" || die "yt-main.sh mới lỗi cú pháp."
  bash -n "$d/yt-exit.sh" || die "yt-exit.sh mới lỗi cú pháp."

  # Chỉ thay file sau khi cả 3 đều tải + kiểm tra thành công.
  install -m 755 "$d/yt.sh" "$SELF"
  install -m 755 "$d/yt-main.sh" "$BASE/yt-main.sh"
  install -m 755 "$d/yt-exit.sh" "$BASE/yt-exit.sh"
  ln -sfn "$BASE/yt-main.sh" /usr/local/bin/yt-main
  ln -sfn "$BASE/yt-exit.sh" /usr/local/bin/yt-exit

  rm -rf "$d"
  trap - RETURN

  ok "Đã cập nhật đồng bộ YT Manager + MAIN + EXIT."
  "$SELF" version
}

role(){
  local main_state=0 exit_state=0
  [[ -f /etc/yt-main/state.env ]] && main_state=1
  [[ -f /etc/yt-exit/state.env ]] && exit_state=1

  if (( main_state == 1 && exit_state == 0 )); then
    echo main
  elif (( exit_state == 1 && main_state == 0 )); then
    echo exit
  elif (( main_state == 1 && exit_state == 1 )); then
    echo conflict
  else
    echo none
  fi
}

open_role(){
  local r="$1"
  ensure_role "$r"
  "$BASE/yt-${r}.sh"
}

token_menu(){
  echo
  echo "1) Nhập/đổi token"
  echo "2) Xóa token"
  echo "0) Quay lại"
  read -rp "Chọn: " t

  case "$t" in
    1) save_token ;;
    2) delete_token ;;
    0) return ;;
    *) warn "Lựa chọn không hợp lệ." ;;
  esac
}

first_menu(){
  while true; do
    clear 2>/dev/null || true
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "       YT MANAGER v${VERSION}"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "VPS này chưa chọn vai trò."
    echo
    echo "1) Cài làm VPS MAIN"
    echo "2) Cài làm VPS EXIT"
    echo "3) GitHub token"
    echo "4) Cập nhật"
    echo "5) Phiên bản"
    echo "0) Thoát"
    echo
    read -rp "Chọn: " c

    case "$c" in
      1) open_role main ;;
      2) open_role exit ;;
      3) token_menu ;;
      4) update_all ;;
      5) echo "YT Manager v$VERSION" ;;
      0) return ;;
      *) warn "Lựa chọn không hợp lệ." ;;
    esac

    echo
    read -rp "Enter để tiếp tục..." _
  done
}

manager_menu(){
  local r="$1"

  while true; do
    clear 2>/dev/null || true
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "       YT MANAGER v${VERSION}"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "Vai trò: ${r^^}"
    echo
    echo "1) Mở quản lý ${r^^}"
    echo "2) Cập nhật tất cả"
    echo "3) GitHub token"
    echo "4) Phiên bản"
    echo "0) Thoát"
    echo
    read -rp "Chọn: " c

    case "$c" in
      1) open_role "$r" ;;
      2) update_all ;;
      3) token_menu ;;
      4) echo "YT Manager v$VERSION" ;;
      0) return ;;
      *) warn "Lựa chọn không hợp lệ." ;;
    esac

    echo
    read -rp "Enter để tiếp tục..." _
  done
}

main_entry(){
  need_root
  install_deps
  install_self

  # Lần đầu người dùng có thể truyền GH_TOKEN trong environment.
  if [[ -n "${GH_TOKEN:-}" && ! -f "$GH_ENV" ]]; then
    save_token "$GH_TOKEN"
  fi

  local r
  r="$(role)"

  case "$r" in
    main|exit)
      manager_menu "$r"
      ;;
    conflict)
      die "Phát hiện cả state MAIN và EXIT trên cùng VPS. Không tiếp tục để tránh xung đột."
      ;;
    none)
      first_menu
      ;;
  esac
}

case "${1:-}" in
  main)
    need_root; install_deps; install_self; open_role main
    ;;
  exit)
    need_root; install_deps; install_self; open_role exit
    ;;
  update)
    need_root; install_deps; install_self; update_all
    ;;
  token)
    need_root; install_self; save_token "${2:-}"
    ;;
  delete-token)
    need_root; delete_token
    ;;
  version)
    echo "YT Manager v$VERSION"
    ;;
  *)
    main_entry
    ;;
esac
