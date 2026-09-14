#!/usr/bin/env bash
set -uo pipefail

BASE_DIR="/opt/yt-exit"
XRAY_BIN="/usr/local/lib/yt-exit/xray"
XRAY_CFG="/etc/yt-exit/config.json"
SERVICE="/etc/systemd/system/yt-exit.service"
STATE_FILE="$BASE_DIR/state.env"
MANAGER_FILE="$BASE_DIR/yt-exit.sh"
MANAGER_BIN="/usr/local/bin/yt"
DEFAULT_PORT=28443
METHOD="2022-blake3-aes-128-gcm"

RED='\033[31m'; GREEN='\033[32m'; YELLOW='\033[33m'; CYAN='\033[36m'; BOLD='\033[1m'; RESET='\033[0m'

need_root(){ [ "${EUID:-$(id -u)}" -eq 0 ] || { echo -e "${RED}Vui lòng chạy bằng root.${RESET}"; exit 1; }; }
have(){ command -v "$1" >/dev/null 2>&1; }

detect_arch(){
  case "$(uname -m)" in
    x86_64|amd64) echo "64" ;;
    aarch64|arm64) echo "arm64-v8a" ;;
    *) echo "unsupported" ;;
  esac
}

ensure_tools(){
  local miss=0
  for c in curl unzip openssl systemctl ss; do have "$c" || miss=1; done
  [ "$miss" -eq 0 ] && return 0
  if have apt-get; then
    apt-get update -qq
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq curl unzip openssl iproute2 ca-certificates
  elif have dnf; then
    dnf install -y curl unzip openssl iproute
  elif have yum; then
    yum install -y curl unzip openssl iproute
  else
    echo -e "${RED}Thiếu công cụ cần thiết và không có package manager hỗ trợ.${RESET}"
    return 1
  fi
}

port_busy(){
  local p="$1"
  ss -lntup 2>/dev/null | awk '{print $5}' | grep -Eq "[:.]${p}$"
}

public_ip(){
  curl -4fsS --max-time 6 https://api.ipify.org 2>/dev/null || true
}

download_xray(){
  local arch tmp url
  arch="$(detect_arch)"
  [ "$arch" != "unsupported" ] || { echo -e "${RED}Không hỗ trợ kiến trúc $(uname -m).${RESET}"; return 1; }
  tmp="$(mktemp -d)" || {
    echo -e "${RED}Không tạo được thư mục tạm để tải Xray.${RESET}"
    return 1
  }
  url="https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-${arch}.zip"
  echo -e "${CYAN}→ Tải Xray-core...${RESET}"
  mkdir -p "$(dirname "$XRAY_BIN")"
  if ! curl -fL --retry 3 --connect-timeout 10 --max-time 180 "$url" -o "$tmp/xray.zip"; then
    rm -rf "$tmp"
    echo -e "${RED}Tải Xray-core thất bại.${RESET}"
    return 1
  fi
  if ! unzip -tq "$tmp/xray.zip" >/dev/null 2>&1; then
    rm -rf "$tmp"
    echo -e "${RED}File Xray tải về bị lỗi/không phải ZIP hợp lệ.${RESET}"
    return 1
  fi
  if ! unzip -q "$tmp/xray.zip" -d "$tmp/xray" || [ ! -x "$tmp/xray/xray" ]; then
    rm -rf "$tmp"
    echo -e "${RED}Không tìm thấy binary Xray hợp lệ trong release.${RESET}"
    return 1
  fi
  if ! "$tmp/xray/xray" version >/dev/null 2>&1; then
    rm -rf "$tmp"
    echo -e "${RED}Binary Xray tải về không chạy được trên VPS này.${RESET}"
    return 1
  fi
  install -m 0755 "$tmp/xray/xray" "$XRAY_BIN" || { rm -rf "$tmp"; return 1; }
  rm -rf "$tmp"
}

write_service(){
  local service_tmp
  service_tmp="$(mktemp "$(dirname "$SERVICE")/.yt-exit.service.tmp.XXXXXX")" || return 1
  cat > "$service_tmp" <<'EOF'
[Unit]
Description=YT EXIT Xray Service
After=network-online.target
Wants=network-online.target
StartLimitIntervalSec=60
StartLimitBurst=10

[Service]
Type=simple
ExecStart=/usr/local/lib/yt-exit/xray run -config /etc/yt-exit/config.json
Restart=on-failure
RestartSec=2
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF
  chmod 0644 "$service_tmp" || { rm -f "$service_tmp"; return 1; }
  mv -f "$service_tmp" "$SERVICE" || { rm -f "$service_tmp"; return 1; }
  systemctl daemon-reload
}

write_config(){
  local port="$1" key="$2"
  mkdir -p "$BASE_DIR" "$(dirname "$XRAY_CFG")"
  local cfg_tmp
  cfg_tmp="$(mktemp "$(dirname "$XRAY_CFG")/.config.json.tmp.XXXXXX")" || return 1
  cat > "$cfg_tmp" <<EOF
{
  "log": { "loglevel": "warning" },
  "inbounds": [
    {
      "tag": "yt-ss-in",
      "listen": "0.0.0.0",
      "port": ${port},
      "protocol": "shadowsocks",
      "settings": {
        "method": "${METHOD}",
        "password": "${key}",
        "network": "tcp,udp"
      }
    }
  ],
  "outbounds": [
    {
      "tag": "direct",
      "protocol": "freedom",
      "settings": {},
      "streamSettings": {
        "sockopt": {
          "domainStrategy": "UseIPv4"
        }
      }
    }
  ]
}
EOF
  chmod 600 "$cfg_tmp"
  mv -f "$cfg_tmp" "$XRAY_CFG"

  local state_tmp
  state_tmp="$(mktemp "$BASE_DIR/.state.env.tmp.XXXXXX")" || return 1
  cat > "$state_tmp" <<EOF
PORT=${port}
METHOD=${METHOD}
KEY=${key}
EOF
  chmod 600 "$state_tmp"
  mv -f "$state_tmp" "$STATE_FILE"
}

load_state(){
  PORT=""; KEY=""
  [ -f "$STATE_FILE" ] || return 0
  PORT="$(sed -n 's/^PORT=//p' "$STATE_FILE" | head -n1)"
  KEY="$(sed -n 's/^KEY=//p' "$STATE_FILE" | head -n1)"
}

installed_ok(){
  load_state
  [ -x "$XRAY_BIN" ] &&
  [ -f "$XRAY_CFG" ] &&
  [ -f "$SERVICE" ] &&
  [[ "${PORT:-}" =~ ^[0-9]+$ ]] &&
  [ "$PORT" -ge 1024 ] &&
  [ "$PORT" -le 65535 ] &&
  [ -n "${KEY:-}" ] &&
  [[ "$KEY" != *$'\n'* ]] &&
  [[ "$KEY" != *$'\r'* ]]
}

listeners_ok(){
  local p="$1"
  ss -lntp 2>/dev/null | grep -q ":${p} " &&
  ss -lnup 2>/dev/null | grep -q ":${p} "
}

firewall_notice(){
  local p="$1"
  echo
  if have ufw && ufw status 2>/dev/null | grep -q '^Status: active'; then
    local ufw_out
    ufw_out="$(ufw status 2>/dev/null || true)"
    if ! grep -Eq "(^|[[:space:]])${p}/tcp([[:space:]]|$)" <<<"$ufw_out" ||        ! grep -Eq "(^|[[:space:]])${p}/udp([[:space:]]|$)" <<<"$ufw_out"; then
      echo -e "${YELLOW}LƯU Ý: UFW đang active nhưng chưa thấy đủ rule TCP + UDP cho port ${p}.${RESET}"
      echo "Script KHÔNG tự sửa firewall. Hãy mở TCP+UDP ${p} nếu MAIN không kết nối được."
    fi
  elif have firewall-cmd && firewall-cmd --state >/dev/null 2>&1; then
    local ports
    ports="$(firewall-cmd --list-ports 2>/dev/null || true)"
    if [[ "$ports" != *"${p}/tcp"* || "$ports" != *"${p}/udp"* ]]; then
      echo -e "${YELLOW}LƯU Ý: firewalld đang chạy nhưng chưa thấy đủ TCP+UDP ${p}.${RESET}"
      echo "Script KHÔNG tự sửa firewall."
    fi
  fi
}

print_info(){
  if ! installed_ok; then
    echo -e "${RED}Chưa có cấu hình YT EXIT hoàn chỉnh/hợp lệ.${RESET}"
    return 1
  fi
  local ip
  ip="$(public_ip)"
  echo
  echo -e "${BOLD}${GREEN}=== YT EXIT INFO ===${RESET}"
  echo "EXIT IP : ${ip:-không xác định}"
  echo "PORT    : ${PORT:-?}"
  echo "METHOD  : ${METHOD}"
  echo "KEY     : ${KEY:-?}"
  echo
  echo "Xray outbound config:"
  cat <<EOF
{
  "tag": "yt_exit",
  "protocol": "shadowsocks",
  "settings": {
    "address": "${ip:-YOUR_EXIT_IP}",
    "port": ${PORT:-$DEFAULT_PORT},
    "method": "${METHOD}",
    "password": "${KEY:-YOUR_KEY}",
    "level": 0
  }
}
EOF
}

install_exit(){
  ensure_tools || return 1
  local port key had_running=0 had_enabled=0 had_binary=0 reinstall_ans="" src_real="" dst_real="" manager_saved=0 prompt_port="$DEFAULT_PORT"

  # Ghi nhớ trạng thái cũ để rollback có thể khôi phục chính xác hơn.
  [ -x "$XRAY_BIN" ] && had_binary=1
  if systemctl is-active --quiet yt-exit 2>/dev/null; then
    had_running=1
  fi
  if systemctl is-enabled --quiet yt-exit 2>/dev/null; then
    had_enabled=1
  fi

  # Nếu đã cài, không âm thầm tạo key mới làm MAIN mất kết nối.
  if [ -f "$STATE_FILE" ] && [ -f "$XRAY_CFG" ] && [ -f "$SERVICE" ]; then
    load_state
    if [[ "${PORT:-}" =~ ^[0-9]+$ ]] && [ "$PORT" -ge 1024 ] && [ "$PORT" -le 65535 ]; then
      prompt_port="$PORT"
    fi
    echo -e "${YELLOW}YT EXIT đã được cài (port ${PORT:-?}).${RESET}"
    read -r -p "Cài lại sẽ tạo KEY mới. Tiếp tục? [y/N]: " reinstall_ans
    [[ "${reinstall_ans:-}" =~ ^[Yy]$ ]] || {
      echo "Giữ nguyên cấu hình hiện tại."
      print_info
      return 0
    }
  fi

  read -r -p "Port Shadowsocks [${prompt_port}]: " port
  port="${port:-$prompt_port}"
  [[ "$port" =~ ^[0-9]+$ ]] && [ "$port" -ge 1024 ] && [ "$port" -le 65535 ] || { echo -e "${RED}Port không hợp lệ.${RESET}"; return 1; }

  if port_busy "$port"; then
    load_state
    if [ "${PORT:-}" != "$port" ] || ! systemctl is-active --quiet yt-exit 2>/dev/null; then
      echo -e "${RED}Port ${port} đang được tiến trình khác sử dụng.${RESET}"
      return 1
    fi
  fi

  if ! mkdir -p "$BASE_DIR/backup"; then
    echo -e "${RED}Không tạo được thư mục backup.${RESET}"
    return 1
  fi
  rm -f "$BASE_DIR/backup/"* 2>/dev/null || true

  if [ -f "$XRAY_CFG" ] && ! cp -a "$XRAY_CFG" "$BASE_DIR/backup/config.json.bak"; then
    echo -e "${RED}Backup config cũ thất bại. Dừng để bảo vệ cấu hình hiện tại.${RESET}"
    return 1
  fi
  if [ -f "$STATE_FILE" ] && ! cp -a "$STATE_FILE" "$BASE_DIR/backup/state.env.bak"; then
    echo -e "${RED}Backup state cũ thất bại. Dừng để bảo vệ cấu hình hiện tại.${RESET}"
    return 1
  fi
  if [ -f "$SERVICE" ] && ! cp -a "$SERVICE" "$BASE_DIR/backup/yt-exit.service.bak"; then
    echo -e "${RED}Backup service cũ thất bại. Dừng để bảo vệ cấu hình hiện tại.${RESET}"
    return 1
  fi
  if [ -x "$XRAY_BIN" ] && ! cp -a "$XRAY_BIN" "$BASE_DIR/backup/xray.bak"; then
    echo -e "${RED}Backup Xray binary cũ thất bại. Dừng để bảo vệ bản đang chạy.${RESET}"
    return 1
  fi

  rollback_install(){
    echo -e "${YELLOW}→ Khôi phục trạng thái YT EXIT trước khi cài...${RESET}"
    systemctl stop yt-exit >/dev/null 2>&1 || true
    if [ -f "$BASE_DIR/backup/config.json.bak" ]; then
      mkdir -p "$(dirname "$XRAY_CFG")"
      cp -a "$BASE_DIR/backup/config.json.bak" "$XRAY_CFG"
      chmod 600 "$XRAY_CFG" >/dev/null 2>&1 || true
    else
      rm -f "$XRAY_CFG"
    fi
    if [ -f "$BASE_DIR/backup/state.env.bak" ]; then
      cp -a "$BASE_DIR/backup/state.env.bak" "$STATE_FILE"
      chmod 600 "$STATE_FILE" >/dev/null 2>&1 || true
    else
      rm -f "$STATE_FILE"
    fi
    if [ -f "$BASE_DIR/backup/yt-exit.service.bak" ]; then
      cp -a "$BASE_DIR/backup/yt-exit.service.bak" "$SERVICE"
    else
      rm -f "$SERVICE"
    fi

    if [ -f "$BASE_DIR/backup/xray.bak" ]; then
      mkdir -p "$(dirname "$XRAY_BIN")"
      install -m 0755 "$BASE_DIR/backup/xray.bak" "$XRAY_BIN" >/dev/null 2>&1 || true
    elif [ "$had_binary" -eq 0 ]; then
      rm -f "$XRAY_BIN"
      rmdir "$(dirname "$XRAY_BIN")" 2>/dev/null || true
    fi

    systemctl daemon-reload >/dev/null 2>&1 || true

    if [ "$had_enabled" -eq 1 ] && [ -f "$SERVICE" ]; then
      systemctl enable yt-exit >/dev/null 2>&1 || true
    else
      systemctl disable yt-exit >/dev/null 2>&1 || true
    fi

    if [ "$had_running" -eq 1 ] && [ -f "$SERVICE" ]; then
      systemctl restart yt-exit >/dev/null 2>&1 || true
    else
      systemctl stop yt-exit >/dev/null 2>&1 || true
    fi
    rm -rf "$BASE_DIR/backup"
  }

  if [ ! -x "$XRAY_BIN" ]; then
    download_xray || { rollback_install; return 1; }
  fi

  key="$(openssl rand -base64 16)" || { rollback_install; return 1; }
  write_config "$port" "$key" || { rollback_install; return 1; }
  write_service || { rollback_install; return 1; }

  echo -e "${CYAN}→ Kiểm tra config...${RESET}"
  if ! "$XRAY_BIN" run -test -config "$XRAY_CFG"; then
    echo -e "${RED}Config Xray không hợp lệ.${RESET}"
    rollback_install
    return 1
  fi

  if ! systemctl enable yt-exit >/dev/null 2>&1; then
    echo -e "${RED}Không enable được yt-exit.service để tự chạy sau reboot.${RESET}"
    rollback_install
    return 1
  fi
  if ! systemctl restart yt-exit; then
    echo -e "${RED}Không khởi động được yt-exit.service.${RESET}"
    rollback_install
    return 1
  fi
  sleep 2

  if ! systemctl is-active --quiet yt-exit || ! listeners_ok "$port"; then
    echo -e "${RED}Health-check thất bại: cần cả service active + TCP + UDP listener.${RESET}"
    ss -lntup | grep ":${port}" || true
    rollback_install
    return 1
  fi

  # Lưu manager trong thư mục riêng, sau đó tạo lệnh ngắn "yt".
  # Không ghi đè một lệnh /usr/local/bin/yt không thuộc YT EXIT.
  if [ -r "${BASH_SOURCE[0]}" ]; then
    src_real="$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || true)"
    dst_real="$(readlink -f "$MANAGER_FILE" 2>/dev/null || true)"
    if [ -n "$src_real" ] && [ "$src_real" = "$dst_real" ]; then
      manager_saved=1
    elif install -m 0755 "${BASH_SOURCE[0]}" "$MANAGER_FILE" 2>/dev/null; then
      manager_saved=1
    else
      manager_saved=0
      echo -e "${YELLOW}LƯU Ý: không lưu được manager vào $MANAGER_FILE; EXIT vẫn chạy bình thường.${RESET}"
    fi

    if [ "$manager_saved" -eq 1 ]; then
      if [ -L "$MANAGER_BIN" ] && [ "$(readlink -f "$MANAGER_BIN" 2>/dev/null || true)" = "$MANAGER_FILE" ]; then
        :
      elif [ -e "$MANAGER_BIN" ] || [ -L "$MANAGER_BIN" ]; then
        echo -e "${YELLOW}LƯU Ý: $MANAGER_BIN đã tồn tại và không thuộc YT EXIT.${RESET}"
        echo "Không ghi đè lệnh đó. Bạn vẫn có thể chạy: $MANAGER_FILE"
      else
        ln -s "$MANAGER_FILE" "$MANAGER_BIN" ||           echo -e "${YELLOW}LƯU Ý: không tạo được lệnh 'yt'; EXIT vẫn chạy bình thường.${RESET}"
      fi
    fi
  fi

  rm -rf "$BASE_DIR/backup"
  echo -e "${GREEN}✓ Cài YT EXIT thành công.${RESET}"
  echo -e "${CYAN}Xray version: $("$XRAY_BIN" version 2>/dev/null | head -1 || true)${RESET}"
  if [ -L "$MANAGER_BIN" ] && [ "$(readlink -f "$MANAGER_BIN" 2>/dev/null || true)" = "$MANAGER_FILE" ]; then
    echo -e "${CYAN}Lần sau chỉ cần gõ: yt${RESET}"
  else
    echo -e "${CYAN}Menu manager: $MANAGER_FILE${RESET}"
  fi
  firewall_notice "$port"
  print_info
}

status_exit(){
  echo -e "${BOLD}${CYAN}=== STATUS ===${RESET}"
  if ! installed_ok; then
    echo -e "YT EXIT: ${YELLOW}chưa cài hoặc cài chưa hoàn chỉnh${RESET}"
    return 1
  fi
  if systemctl is-active --quiet yt-exit; then
    echo -e "YT EXIT: ${GREEN}active${RESET}"
  else
    echo -e "YT EXIT: ${RED}inactive${RESET}"
  fi
  ss -lntup | grep ":${PORT}" || true
}

test_exit(){
  installed_ok || { echo -e "${RED}YT EXIT chưa cài hoàn chỉnh.${RESET}"; return 1; }
  if ! "$XRAY_BIN" run -test -config "$XRAY_CFG"; then
    echo -e "${RED}FAIL: config Xray không hợp lệ.${RESET}"
    return 1
  fi
  if systemctl is-active --quiet yt-exit && listeners_ok "$PORT"; then
    echo -e "${GREEN}PASS LOCAL: service active + TCP/UDP listener OK.${RESET}"
    echo "Lưu ý: đây là kiểm tra trên EXIT; kết nối MAIN → EXIT vẫn cần test riêng."
  else
    echo -e "${RED}FAIL${RESET}"; return 1
  fi
}

change_exit(){
  installed_ok || { echo -e "${RED}YT EXIT chưa cài hoàn chỉnh.${RESET}"; return 1; }
  local np nk ans
  read -r -p "Port mới [${PORT}]: " np
  np="${np:-$PORT}"
  [[ "$np" =~ ^[0-9]+$ ]] && [ "$np" -ge 1024 ] && [ "$np" -le 65535 ] || { echo -e "${RED}Port không hợp lệ.${RESET}"; return 1; }
  if [ "$np" != "$PORT" ] && port_busy "$np"; then
    echo -e "${RED}Port ${np} đang bận.${RESET}"
    return 1
  fi

  read -r -p "Tạo key mới? [y/N]: " ans
  if [[ "${ans:-}" =~ ^[Yy]$ ]]; then nk="$(openssl rand -base64 16)"; else nk="$KEY"; fi

  local cfg_bak state_bak
  cfg_bak="$(mktemp)" || { echo -e "${RED}Không tạo được file backup tạm.${RESET}"; return 1; }
  state_bak="$(mktemp)" || { rm -f "$cfg_bak"; echo -e "${RED}Không tạo được file backup tạm.${RESET}"; return 1; }
  if ! cp -a "$XRAY_CFG" "$cfg_bak"; then
    rm -f "$cfg_bak" "$state_bak"
    echo -e "${RED}Backup config thất bại; chưa thay đổi gì.${RESET}"
    return 1
  fi
  if ! cp -a "$STATE_FILE" "$state_bak"; then
    rm -f "$cfg_bak" "$state_bak"
    echo -e "${RED}Backup state thất bại; chưa thay đổi gì.${RESET}"
    return 1
  fi

  if ! write_config "$np" "$nk" || ! "$XRAY_BIN" run -test -config "$XRAY_CFG"; then
    cp -a "$cfg_bak" "$XRAY_CFG"
    cp -a "$state_bak" "$STATE_FILE"
    rm -f "$cfg_bak" "$state_bak"
    echo -e "${RED}Config mới không hợp lệ; đã khôi phục config cũ.${RESET}"
    return 1
  fi

  if ! systemctl restart yt-exit; then
    cp -a "$cfg_bak" "$XRAY_CFG"
    cp -a "$state_bak" "$STATE_FILE"
    systemctl restart yt-exit >/dev/null 2>&1 || true
    rm -f "$cfg_bak" "$state_bak"
    echo -e "${RED}Restart thất bại; đã rollback config cũ.${RESET}"
    return 1
  fi
  sleep 2

  if ! systemctl is-active --quiet yt-exit || ! listeners_ok "$np"; then
    cp -a "$cfg_bak" "$XRAY_CFG"
    cp -a "$state_bak" "$STATE_FILE"
    systemctl restart yt-exit >/dev/null 2>&1 || true
    rm -f "$cfg_bak" "$state_bak"
    echo -e "${RED}Listener mới không đạt; đã rollback config cũ.${RESET}"
    return 1
  fi

  rm -f "$cfg_bak" "$state_bak"
  echo -e "${GREEN}✓ Đã cập nhật.${RESET}"
  print_info
}

update_xray(){
  ensure_tools || return 1
  installed_ok || { echo -e "${RED}YT EXIT chưa cài hoàn chỉnh; không update để tránh làm trạng thái xấu hơn.${RESET}"; return 1; }
  if ! systemctl is-active --quiet yt-exit || ! listeners_ok "$PORT"; then
    echo -e "${RED}YT EXIT hiện không healthy; hãy sửa trạng thái trước khi update Xray.${RESET}"
    return 1
  fi

  local bin_bak
  bin_bak="$(mktemp)" || { echo -e "${RED}Không tạo được file backup tạm.${RESET}"; return 1; }
  if [ -x "$XRAY_BIN" ]; then
    if ! cp -a "$XRAY_BIN" "$bin_bak"; then
      rm -f "$bin_bak"
      echo -e "${RED}Backup Xray hiện tại thất bại; hủy update để tránh mất bản đang chạy.${RESET}"
      return 1
    fi
  else
    : > "$bin_bak"
  fi

  if ! download_xray || ! "$XRAY_BIN" run -test -config "$XRAY_CFG"; then
    if [ -s "$bin_bak" ]; then install -m 0755 "$bin_bak" "$XRAY_BIN"; fi
    rm -f "$bin_bak"
    echo -e "${RED}Bản Xray mới không dùng được; đã giữ/khôi phục bản cũ.${RESET}"
    return 1
  fi

  if ! systemctl restart yt-exit; then
    if [ -s "$bin_bak" ]; then install -m 0755 "$bin_bak" "$XRAY_BIN"; fi
    systemctl restart yt-exit >/dev/null 2>&1 || true
    rm -f "$bin_bak"
    echo -e "${RED}Update thất bại; đã rollback binary cũ.${RESET}"
    return 1
  fi

  sleep 2
  load_state
  if ! systemctl is-active --quiet yt-exit || ! listeners_ok "$PORT"; then
    if [ -s "$bin_bak" ]; then install -m 0755 "$bin_bak" "$XRAY_BIN"; fi
    systemctl restart yt-exit >/dev/null 2>&1 || true
    rm -f "$bin_bak"
    echo -e "${RED}Health-check sau update thất bại; đã rollback binary cũ.${RESET}"
    return 1
  fi

  rm -f "$bin_bak"
  echo -e "${GREEN}✓ Đã cập nhật Xray-core và health-check PASS.${RESET}"
}

uninstall_exit(){
  local ans
  read -r -p "Gỡ YT EXIT? [y/N]: " ans
  [[ "${ans:-}" =~ ^[Yy]$ ]] || return 0
  systemctl disable --now yt-exit >/dev/null 2>&1 || true
  rm -f "$SERVICE"
  systemctl daemon-reload
  if [ -L "$MANAGER_BIN" ] && [ "$(readlink -f "$MANAGER_BIN" 2>/dev/null || true)" = "$MANAGER_FILE" ]; then
    rm -f "$MANAGER_BIN"
  fi
  # Dọn alias cũ chỉ khi nó là symlink trỏ vào YT EXIT.
  if [ -L /usr/local/bin/yt-exit ]; then
    case "$(readlink -f /usr/local/bin/yt-exit 2>/dev/null || true)" in
      "$BASE_DIR"/*) rm -f /usr/local/bin/yt-exit ;;
    esac
  fi
  rm -rf "$BASE_DIR"
  rm -f "$XRAY_CFG"
  rm -rf "$(dirname "$XRAY_BIN")"
  rmdir /etc/yt-exit 2>/dev/null || true
  echo -e "${YELLOW}Đã gỡ toàn bộ thành phần YT EXIT. Không đụng V2Node/Xray khác.${RESET}"
}

menu(){
  while true; do
    clear || true
    echo -e "${BOLD}${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "       YOUTUBE EXIT MANAGER"
    echo -e "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
    echo "1) Cài đặt EXIT"
    echo "2) Xem trạng thái"
    echo "3) Xem thông tin kết nối"
    echo "4) Đổi Port / tạo Key mới"
    echo "5) Test EXIT"
    echo "6) Cập nhật Xray-core"
    echo "7) Gỡ cài đặt"
    echo "0) Thoát"
    echo
    read -r -p "Lựa chọn: " c
    case "$c" in
      1) install_exit || true ;;
      2) status_exit || true ;;
      3) print_info || true ;;
      4) change_exit || true ;;
      5) test_exit || true ;;
      6) update_xray || true ;;
      7) uninstall_exit || true ;;
      0) exit 0 ;;
      *) echo "Lựa chọn không hợp lệ" ;;
    esac
    echo
    read -r -p "Nhấn Enter để tiếp tục..." _
  done
}

need_root
case "${1:-}" in
  install) install_exit ;;
  status) status_exit ;;
  info) print_info ;;
  test) test_exit ;;
  update) update_xray ;;
  uninstall) uninstall_exit ;;
  *) menu ;;
esac
