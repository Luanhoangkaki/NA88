#!/usr/bin/env bash
set -e
set -u
# Thử kích hoạt pipefail (nếu hỗ trợ)
if (set -o pipefail 2>/dev/null); then
  set -o pipefail
fi

# Đường dẫn tệp cấu hình V2Node
CONFIG_FILE="/etc/v2node/config.json"
BACKUP_DIR="/etc/v2node/backups"
V2NODE_BIN="/usr/local/v2node/v2node"
V2NODE_VERSION="2.0.1"
V2NODE_RELEASE_URL="https://github.com/Luanhoangkaki/NA88/releases/download/v2node-pro-v2.0.1/v2node-linux-amd64"
V2NODE_SHA256="7bca4ab8fef66143fb7df8b548899ebb8aa35f945cdb575871d480745eb75808"
SERVICE_FILE="/etc/systemd/system/v2node.service"
DROPIN_DIR="/etc/systemd/system/v2node.service.d"
DROPIN_FILE="$DROPIN_DIR/10-gc-tuning.conf"

# Màu sắc kiểu dáng
RED='\033[31m'
GREEN='\033[32m'
YELLOW='\033[33m'
BLUE='\033[34m'
CYAN='\033[36m'
GRAY='\033[90m'
BOLD='\033[1m'
RESET='\033[0m'

# Kiểm tra quyền root
check_root() {
  if [[ $EUID -ne 0 ]]; then
    echo -e "${RED}Lỗi: Script này cần quyền root để chạy!${RESET}"
    echo -e "${YELLOW}Vui lòng chạy với: sudo $0${RESET}"
    exit 1
  fi
}

# Kiểm tra jq đã cài đặt chưa
check_jq() {
  if ! command -v jq &> /dev/null; then
    echo -e "${RED}Lỗi: jq chưa được cài đặt${RESET}"
    echo -e "${YELLOW}Đang tự động cài đặt jq...${RESET}"
    if command -v apt-get &> /dev/null; then
      apt-get update -qq && apt-get install -y -qq jq > /dev/null 2>&1
    elif command -v yum &> /dev/null; then
      yum install -y -q jq > /dev/null 2>&1
    elif command -v apk &> /dev/null; then
      apk add --no-cache jq > /dev/null 2>&1
    else
      echo -e "${RED}Không thể tự động cài đặt jq!${RESET}"
      echo -e "${YELLOW}Vui lòng cài đặt thủ công: apt-get install jq hoặc yum install jq${RESET}"
      exit 1
    fi
    if command -v jq &> /dev/null; then
      echo -e "${GREEN}✓ Đã cài đặt jq thành công${RESET}"
    fi
  fi
}

# Kiểm tra v2node đã cài đặt chưa
check_v2node() {
  if [[ ! -f "$V2NODE_BIN" ]]; then
    return 1
  fi
  return 0
}

# Tạo backup config trước khi sửa
backup_config() {
  if [[ -f "$CONFIG_FILE" ]]; then
    mkdir -p "$BACKUP_DIR"
    local backup_file="${BACKUP_DIR}/config_$(date +%Y%m%d_%H%M%S).json"
    cp "$CONFIG_FILE" "$backup_file"
    echo -e "${GRAY}→ Đã backup config: $(basename $backup_file)${RESET}"
    
    # Giữ tối đa 10 backup gần nhất
    ls -t "$BACKUP_DIR"/config_*.json 2>/dev/null | tail -n +11 | xargs -r rm
  fi
}

# Kiểm tra tồn tại tệp cấu hình
check_config() {
  if [[ ! -f "$CONFIG_FILE" ]]; then
    echo -e "${RED}Tệp cấu hình không tồn tại: $CONFIG_FILE${RESET}"
    echo -e "${YELLOW}Đang tạo tệp cấu hình mặc định...${RESET}"
    sudo mkdir -p "$(dirname "$CONFIG_FILE")"
    sudo tee "$CONFIG_FILE" > /dev/null <<EOF
{
    "Log": {
        "Level": "none",
        "Output": "",
        "Access": "none"
    },
    "Nodes": [],
    "PprofPort": 6060
}
EOF
    chmod 600 "$CONFIG_FILE"
    echo -e "${GREEN}Đã tạo tệp cấu hình mặc định${RESET}"
  fi
}

# Khởi động lại dịch vụ v2node
restart_v2node() {
  echo ""
  echo -e "${YELLOW}Đang khởi động lại dịch vụ v2node...${RESET}"
  
  # Thử sử dụng systemctl
  if command -v systemctl >/dev/null 2>&1; then
    if systemctl list-units --type=service --all | grep -q "v2node"; then
      if sudo systemctl restart v2node 2>/dev/null; then
        echo -e "${GREEN}Dịch vụ v2node đã khởi động lại${RESET}"
        return 0
      fi
    fi
  fi
  
  # Thử sử dụng lệnh service
  if command -v service >/dev/null 2>&1; then
    if sudo service v2node restart 2>/dev/null; then
      echo -e "${GREEN}Dịch vụ v2node đã khởi động lại${RESET}"
      return 0
    fi
  fi
  
  # Nếu tất cả thất bại, nhắc khởi động lại thủ công
  echo -e "${YELLOW}Không thể tự động khởi động lại dịch vụ v2node, vui lòng khởi động lại thủ công${RESET}"
  echo -e "${GRAY}Có thể thử: systemctl restart v2node hoặc service v2node restart${RESET}"
  return 1
}

# Che API key khi hiển thị trên màn hình
mask_api_key() {
  local key="${1:-}"
  local len=${#key}
  if (( len <= 4 )); then
    printf '%s' '****'
  elif (( len <= 8 )); then
    printf '%s****' "${key:0:2}"
  else
    printf '%s****%s' "${key:0:4}" "${key: -4}"
  fi
}

# Liệt kê tất cả các node
list_nodes() {
  echo -e "${BOLD}${CYAN}Danh sách node hiện tại:${RESET}"
  echo ""
  
  local node_count=$(sudo jq '.Nodes | length' "$CONFIG_FILE")
  
  if [[ "$node_count" -eq 0 ]]; then
    echo -e "${YELLOW}Chưa có node nào${RESET}"
    return
  fi
  
  echo -e "${GRAY}Tổng $node_count node${RESET}"
  echo ""
  
  # Sử dụng jq để định dạng đầu ra
  sudo jq -r '.Nodes | to_entries | .[] | 
    "Node #\(.key + 1)\n" +
    "  NodeID: \(.value.NodeID)\n" +
    "  ApiHost: \(.value.ApiHost)\n" +
    "  ApiKey: " + ((.value.ApiKey // "") as $k | if ($k|length) <= 4 then "****" elif ($k|length) <= 8 then ($k[0:2] + "****") else ($k[0:4] + "****" + $k[-4:]) end) + "\n" +
    "  Timeout: \(.value.Timeout)\n"' "$CONFIG_FILE"
}

# Cài đặt/cập nhật V2node Pro RAM-fix
ensure_v2node_service() {
  mkdir -p /usr/local/v2node "$DROPIN_DIR"
  cat > "$SERVICE_FILE" <<'SERVICE'
[Unit]
Description=v2node Service
After=network.target nss-lookup.target
Wants=network.target

[Service]
User=root
Group=root
Type=simple
LimitAS=infinity
LimitRSS=infinity
LimitCORE=infinity
LimitNOFILE=999999
WorkingDirectory=/usr/local/v2node/
ExecStart=/usr/local/v2node/v2node server
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
SERVICE

  cat > "$DROPIN_FILE" <<'DROPIN'
[Service]
Environment="GOGC=75"
DROPIN
  systemctl daemon-reload
  systemctl enable v2node >/dev/null 2>&1 || true
}

download_v2node_pro() {
  local tmp_file actual_sha backup_file="" service_backup="" dropin_backup=""
  local had_service=0 had_dropin=0 was_enabled=0 was_active=0
  local backup_tag
  local arch
  arch="$(uname -m)"
  if [[ "$arch" != "x86_64" && "$arch" != "amd64" ]]; then
    echo -e "${RED}Lỗi: V2node Pro V ${V2NODE_VERSION} hiện chỉ hỗ trợ AMD64/x86_64. CPU: $arch${RESET}"
    return 1
  fi

  # V2node Pro được quản lý bằng systemd; kiểm tra trước khi thay bất kỳ file nào.
  if ! command -v systemctl >/dev/null 2>&1; then
    echo -e "${RED}Lỗi: Không tìm thấy systemctl/systemd. Binary hiện tại không bị thay đổi.${RESET}"
    return 1
  fi

  if ! command -v curl >/dev/null 2>&1; then
    echo -e "${YELLOW}Đang cài curl và ca-certificates...${RESET}"
    if command -v apt-get >/dev/null 2>&1; then
      apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq curl ca-certificates
    else
      echo -e "${RED}Không tìm thấy curl. Hãy cài curl rồi chạy lại.${RESET}"
      return 1
    fi
  fi

  tmp_file="$(mktemp /tmp/v2node-pro.XXXXXX)"
  echo -e "${YELLOW}Đang tải V2node Pro V ${V2NODE_VERSION}...${RESET}"
  if ! curl -fL --retry 3 --connect-timeout 15 -o "$tmp_file" "$V2NODE_RELEASE_URL"; then
    rm -f "$tmp_file"
    echo -e "${RED}Tải binary thất bại. Binary hiện tại không bị thay đổi.${RESET}"
    return 1
  fi

  actual_sha="$(sha256sum "$tmp_file" | awk '{print $1}')"
  if [[ "$actual_sha" != "$V2NODE_SHA256" ]]; then
    echo -e "${RED}SHA256 không khớp. Hủy cài đặt.${RESET}"
    echo "Expected: $V2NODE_SHA256"
    echo "Actual  : $actual_sha"
    rm -f "$tmp_file"
    return 1
  fi
  echo -e "${GREEN}✓ SHA256 chính xác${RESET}"

  mkdir -p /usr/local/v2node
  backup_tag="$(date +%Y%m%d_%H%M%S)"
  if [[ -f "$V2NODE_BIN" ]]; then
    backup_file="${V2NODE_BIN}.before-pro-${backup_tag}"
    cp -a "$V2NODE_BIN" "$backup_file"
    echo -e "${GRAY}→ Backup binary: $backup_file${RESET}"
  fi

  # Ghi nhận trạng thái systemd trước khi thay đổi để rollback đúng cả enable/active.
  if systemctl is-enabled --quiet v2node 2>/dev/null; then
    was_enabled=1
  fi
  if systemctl is-active --quiet v2node 2>/dev/null; then
    was_active=1
  fi

  # Backup systemd service/drop-in để rollback đầy đủ nếu cần
  if [[ -f "$SERVICE_FILE" ]]; then
    had_service=1
    service_backup="${SERVICE_FILE}.before-pro-${backup_tag}"
    cp -a "$SERVICE_FILE" "$service_backup"
  fi
  if [[ -f "$DROPIN_FILE" ]]; then
    had_dropin=1
    dropin_backup="${DROPIN_FILE}.before-pro-${backup_tag}"
    cp -a "$DROPIN_FILE" "$dropin_backup"
  fi

  install -m 755 "$tmp_file" "$V2NODE_BIN"
  rm -f "$tmp_file"
  ensure_v2node_service

  if systemctl restart v2node && sleep 2 && systemctl is-active --quiet v2node; then
    echo -e "${GREEN}✓ V2node Pro V ${V2NODE_VERSION} đang chạy${RESET}"
    return 0
  fi

  echo -e "${RED}V2node mới không khởi động được.${RESET}"
  echo -e "${YELLOW}Đang tự động rollback...${RESET}"

  # Khôi phục service/drop-in đúng trạng thái trước khi cài
  if [[ "$had_service" -eq 1 && -f "$service_backup" ]]; then
    cp -a "$service_backup" "$SERVICE_FILE"
  else
    rm -f "$SERVICE_FILE"
  fi
  if [[ "$had_dropin" -eq 1 && -f "$dropin_backup" ]]; then
    mkdir -p "$DROPIN_DIR"
    cp -a "$dropin_backup" "$DROPIN_FILE"
  else
    rm -f "$DROPIN_FILE"
  fi

  if [[ -n "$backup_file" && -f "$backup_file" ]]; then
    cp -a "$backup_file" "$V2NODE_BIN"
    chmod 755 "$V2NODE_BIN"
  else
    rm -f "$V2NODE_BIN"
  fi

  systemctl daemon-reload
  if [[ -n "$backup_file" && -f "$backup_file" ]]; then
    if [[ "$was_enabled" -eq 1 ]]; then
      systemctl enable v2node >/dev/null 2>&1 || true
    else
      systemctl disable v2node >/dev/null 2>&1 || true
    fi

    if [[ "$was_active" -eq 1 ]]; then
      systemctl restart v2node >/dev/null 2>&1 || true
      if systemctl is-active --quiet v2node; then
        echo -e "${GREEN}✓ Đã rollback đầy đủ và v2node cũ đang chạy lại.${RESET}"
      else
        echo -e "${RED}Đã khôi phục file cũ nhưng service chưa chạy. Kiểm tra: systemctl status v2node${RESET}"
      fi
    else
      systemctl stop v2node >/dev/null 2>&1 || true
      echo -e "${GREEN}✓ Đã rollback và giữ nguyên trạng thái service trước đó (không chạy).${RESET}"
    fi
  else
    systemctl stop v2node >/dev/null 2>&1 || true
    systemctl disable v2node >/dev/null 2>&1 || true
    systemctl reset-failed v2node >/dev/null 2>&1 || true
    echo -e "${YELLOW}Đã trả máy về trạng thái trước lần cài mới.${RESET}"
  fi
  return 1
}

install_v2node() {
  echo -e "${BOLD}${CYAN}Cài đặt V2node Pro V ${V2NODE_VERSION}${RESET}"
  echo ""
  if check_v2node; then
    echo -e "${YELLOW}V2Node đã được cài đặt tại: $V2NODE_BIN${RESET}"
    echo -en "${BOLD}Bạn có muốn cài lại V2node Pro V ${V2NODE_VERSION} không? [y/N]: ${RESET}"
    read -r confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
      echo -e "${GREEN}Hủy cài đặt${RESET}"
      return
    fi
  fi
  if ! download_v2node_pro; then
    echo -e "${RED}✗ Cài đặt/cài lại V2node Pro thất bại. Manager vẫn tiếp tục chạy.${RESET}"
    return 0
  fi
}

update_v2node() {
  echo -e "${BOLD}${CYAN}Cập nhật V2node Pro V ${V2NODE_VERSION}${RESET}"
  echo ""
  if ! download_v2node_pro; then
    echo -e "${RED}✗ Cập nhật V2node Pro thất bại. Manager vẫn tiếp tục chạy.${RESET}"
    return 0
  fi
}

# Xem trạng thái dịch vụ v2node  
show_v2node_status() {
  echo -e "${BOLD}${CYAN}Trạng thái V2Node${RESET}"
  echo ""
  
  if ! check_v2node; then
    echo -e "${RED}✗ V2Node chưa được cài đặt${RESET}"
    return 1
  fi
  
  echo -e "${GREEN}✓ V2Node đã cài đặt${RESET}"
  echo -e "${GRAY}Vị trí: $V2NODE_BIN${RESET}"
  echo ""
  
  # Kiểm tra dịch vụ
  if command -v systemctl >/dev/null 2>&1; then
    if systemctl is-active --quiet v2node; then
      echo -e "${GREEN}✓ Dịch vụ đang chạy${RESET}"
    else
      echo -e "${YELLOW}⚠ Dịch vụ không chạy${RESET}"
    fi
    
    if systemctl is-enabled --quiet v2node 2>/dev/null; then
      echo -e "${GREEN}✓ Khởi động cùng hệ thống: Bật${RESET}"
    else
      echo -e "${GRAY}○ Khởi động cùng hệ thống: Tắt${RESET}"
    fi
  fi
  
  echo ""
  echo -e "${GRAY}Phiên bản:${RESET}"
  $V2NODE_BIN version 2>/dev/null || echo "Không xác định được"
}

# Xóa node (có backup)
delete_node() {
  backup_config
  list_nodes
  echo ""
  
  local node_count=$(sudo jq '.Nodes | length' "$CONFIG_FILE")
  if [[ "$node_count" -eq 0 ]]; then
    echo -e "${YELLOW}Không có node nào để xóa${RESET}"
    return
  fi
  
  echo -en "${BOLD}Nhập số thứ tự node hoặc NodeID cần xóa (1-$node_count hoặc NodeID, hỗ trợ đơn lẻ, phạm vi hoặc phân tách bằng dấu phẩy, ví dụ 1,3,5 hoặc 1-5 hoặc 96-98): ${RESET}"
  read -r input
  
  if [[ -z "$input" ]]; then
    echo -e "${RED}Hủy thao tác${RESET}"
    return
  fi
  
  # Lấy danh sách tất cả NodeID (để xóa thông qua NodeID)
  local nodeid_list=()
  local nodeid_to_index=()
  local index=0
  while IFS= read -r nodeid; do
    nodeid_list+=("$nodeid")
    nodeid_to_index["$nodeid"]=$index
    index=$((index + 1))
  done < <(sudo jq -r '.Nodes[].NodeID' "$CONFIG_FILE")
  
  # Phân tích đầu vào (hỗ trợ nhiều số phân tách bằng dấu phẩy và phạm vi)
  local all_numbers=()
  IFS=',' read -ra parts <<< "$input"
  
  # Xử lý từng phần (có thể là số đơn lẻ hoặc phạm vi)
  for part in "${parts[@]}"; do
    part=$(echo "$part" | tr -d ' ')
    if [[ -z "$part" ]]; then
      continue
    fi
    
    # Thử phân tích thành phạm vi hoặc số đơn lẻ
    # Trước hết kiểm tra có phải là số nguyên thuần không (đơn lẻ)
    if [[ "$part" =~ ^[0-9]+$ ]]; then
      all_numbers+=("$part")
    # Kiểm tra xem có phải là định dạng phạm vi không
    elif [[ "$part" =~ ^[0-9]+-[0-9]+$ ]]; then
      local start=$(echo "$part" | cut -d'-' -f1)
      local end=$(echo "$part" | cut -d'-' -f2)
      
      if [[ "$start" -le "$end" ]]; then
        for ((i=start; i<=end; i++)); do
          all_numbers+=("$i")
        done
      else
        echo -e "${RED}Lỗi phạm vi: giá trị bắt đầu phải nhỏ hơn hoặc bằng giá trị kết thúc ($part)${RESET}"
        return
      fi
    else
      echo -e "${RED}Định dạng đầu vào không hợp lệ: $part (vui lòng nhập số hoặc phạm vi, ví dụ 96 hoặc 96-98)${RESET}"
      return
    fi
  done
  
  if [[ ${#all_numbers[@]} -eq 0 ]]; then
    echo -e "${RED}Không có đầu vào hợp lệ${RESET}"
    return
  fi
  
  # Phán đoán là số thứ tự node hay NodeID, và chuyển đổi thành chỉ số mảng
  local delete_indices=()
  declare -A seen
  
  for num in "${all_numbers[@]}"; do
    # Trước tiên thử làm số thứ tự node (1 đến node_count)
    if [[ "$num" -ge 1 ]] && [[ "$num" -le "$node_count" ]]; then
      local idx=$((num - 1))
      if [[ -z "${seen[$idx]:-}" ]]; then
        seen[$idx]=1
        delete_indices+=($idx)
      fi
    else
      # Nếu không phải số thứ tự node, thử làm NodeID
      local found=false
      for i in "${!nodeid_list[@]}"; do
        if [[ "${nodeid_list[$i]}" == "$num" ]]; then
          if [[ -z "${seen[$i]:-}" ]]; then
            seen[$i]=1
            delete_indices+=($i)
            found=true
          fi
          break
        fi
      done
      
      if [[ "$found" == "false" ]]; then
        echo -e "${YELLOW}Cảnh báo: Không tìm thấy NodeID $num, bỏ qua${RESET}"
      fi
    fi
  done
  
  if [[ ${#delete_indices[@]} -eq 0 ]]; then
    echo -e "${RED}Không tìm thấy node cần xóa${RESET}"
    return
  fi
  
  # Sắp xếp (từ lớn đến nhỏ, tránh chỉ số thay đổi sau khi xóa)
  IFS=$'\n' delete_indices=($(printf '%s\n' "${delete_indices[@]}" | sort -rn))
  
  # Xóa node (xóa từ sau ra trước, tránh chỉ số thay đổi)
  local temp_file=$(mktemp)
  sudo cp "$CONFIG_FILE" "$temp_file"
  
  for idx in "${delete_indices[@]}"; do
    sudo jq "del(.Nodes[$idx])" "$temp_file" > "${temp_file}.new"
    mv "${temp_file}.new" "$temp_file"
  done
  
  sudo mv "$temp_file" "$CONFIG_FILE"
  sudo chmod 600 "$CONFIG_FILE"
  
  echo -e "${GREEN}Đã xóa ${#delete_indices[@]} node${RESET}"
  
  # Khởi động lại dịch vụ v2node; nếu lỗi vẫn giữ Manager hoạt động để người dùng kiểm tra.
  if ! restart_v2node; then
    echo -e "${YELLOW}Node đã được xóa khỏi config nhưng service chưa restart thành công.${RESET}"
  fi
}

# Phân tích đầu vào phạm vi (ví dụ 1-5)
parse_range() {
  local input="$1"
  local result=()
  local part start end i existing duplicate

  IFS=',' read -ra parts <<< "$input"
  for part in "${parts[@]}"; do
    part="${part//[[:space:]]/}"
    [[ -n "$part" ]] || continue

    if [[ "$part" =~ ^[1-9][0-9]*$ ]]; then
      result+=("$part")
    elif [[ "$part" =~ ^([1-9][0-9]*)-([1-9][0-9]*)$ ]]; then
      start="${BASH_REMATCH[1]}"
      end="${BASH_REMATCH[2]}"
      if (( start > end )); then
        echo -e "${RED}Lỗi phạm vi: $part${RESET}" >&2
        return 1
      fi
      for ((i=start; i<=end; i++)); do
        result+=("$i")
      done
    else
      echo -e "${RED}Lỗi định dạng NodeID: $part${RESET}" >&2
      return 1
    fi
  done

  local unique=()
  for i in "${result[@]}"; do
    duplicate=false
    for existing in "${unique[@]:-}"; do
      [[ "$existing" == "$i" ]] && duplicate=true && break
    done
    [[ "$duplicate" == "true" ]] || unique+=("$i")
  done

  [[ ${#unique[@]} -gt 0 ]] || return 1
  echo "${unique[*]}"
}

# Thêm node (có backup)
add_node() {
  backup_config
  echo -e "${BOLD}${CYAN}Thêm node mới${RESET}"
  echo ""
  
  local node_count=$(sudo jq '.Nodes | length' "$CONFIG_FILE")
  local api_host=""
  local api_key=""
  local timeout=15
  
  # Nếu có node hiện có, hỏi có muốn dùng lại không
  if [[ "$node_count" -gt 0 ]]; then
    echo -e "${BOLD}Có dùng lại ApiHost và ApiKey của node hiện có không?${RESET}"
    echo -e "  ${YELLOW}1)${RESET} Có, chọn node hiện có"
    echo -e "  ${YELLOW}2)${RESET} Không, nhập thủ công"
    echo -en "${BOLD}Lựa chọn của bạn (mặc định: 2): ${RESET}"
    read -r use_existing
    
    if [[ "$use_existing" == "1" ]]; then
      # Liệt kê tất cả node để chọn
      echo ""
      echo -e "${BOLD}${CYAN}Vui lòng chọn node cần dùng lại:${RESET}"
      echo ""
      
      # Hiển thị danh sách node
      local index=0
      while IFS=$'\t' read -r nodeid host key; do
        index=$((index + 1))
        echo -e "  ${YELLOW}$index)${RESET} NodeID: $nodeid, ApiHost: $host"
      done < <(sudo jq -r '.Nodes[] | "\(.NodeID)\t\(.ApiHost)\t\(.ApiKey)"' "$CONFIG_FILE")
      
      echo ""
      echo -en "${BOLD}Nhập số thứ tự node (1-$node_count): ${RESET}"
      read -r selected_index
      
      if [[ -z "$selected_index" ]] || ! [[ "$selected_index" =~ ^[0-9]+$ ]] || [[ "$selected_index" -lt 1 ]] || [[ "$selected_index" -gt "$node_count" ]]; then
        echo -e "${RED}Số thứ tự node không hợp lệ, hủy thao tác${RESET}"
        return
      fi
      
      local array_index=$((selected_index - 1))
      api_host=$(sudo jq -r ".Nodes[$array_index].ApiHost" "$CONFIG_FILE")
      api_key=$(sudo jq -r ".Nodes[$array_index].ApiKey" "$CONFIG_FILE")
      timeout=$(sudo jq -r ".Nodes[$array_index].Timeout" "$CONFIG_FILE")
      
      echo ""
      echo -e "${GREEN}Đã chọn cấu hình node:${RESET}"
      echo -e "  ${GRAY}ApiHost: $api_host${RESET}"
      echo -e "  ${GRAY}ApiKey: $(mask_api_key "$api_key")${RESET}"
      echo -e "  ${GRAY}Timeout: $timeout${RESET}"
      echo ""
    else
      # Nhập cấu hình thủ công
      echo ""
      echo -en "${BOLD}API Host: ${RESET}"
      read -r api_host
      if [[ -z "$api_host" ]]; then
        echo -e "${RED}API Host không được để trống${RESET}"
        return
      fi
      
      echo -en "${BOLD}API Key: ${RESET}"
      read -rs api_key
      echo ""
      if [[ -z "$api_key" ]]; then
        echo -e "${RED}API Key không được để trống${RESET}"
        return
      fi
      
      echo -en "${BOLD}Timeout (mặc định: 15): ${RESET}"
      read -r timeout_input
      timeout=${timeout_input:-15}
    fi
  else
    # Không có node hiện có, phải nhập thủ công
    echo -en "${BOLD}API Host: ${RESET}"
    read -r api_host
    if [[ -z "$api_host" ]]; then
      echo -e "${RED}API Host không được để trống${RESET}"
      return
    fi
    
    echo -en "${BOLD}API Key: ${RESET}"
    read -rs api_key
    echo ""
    if [[ -z "$api_key" ]]; then
      echo -e "${RED}API Key không được để trống${RESET}"
      return
    fi
    
    echo -en "${BOLD}Timeout (mặc định: 15): ${RESET}"
    read -r timeout_input
    timeout=${timeout_input:-15}
  fi

  # Xác thực cấu hình trước khi tạo JSON.
  # Tránh jq --argjson làm thoát toàn bộ manager khi nhập sai Timeout.
  case "$api_host" in
    http://*|https://*) ;;
    *)
      echo -e "${RED}API Host phải bắt đầu bằng http:// hoặc https://${RESET}"
      return
      ;;
  esac

  if [[ ! "$timeout" =~ ^[1-9][0-9]*$ ]]; then
    echo -e "${RED}Timeout phải là số nguyên dương.${RESET}"
    return
  fi
  
  # Nhập NodeID
  echo ""
  echo -en "${BOLD}NodeID (ví dụ 95 | 95,96,100 | 95-100 | 95-100,105): ${RESET}"
  read -r nodeid_input
  
  if [[ -z "$nodeid_input" ]]; then
    echo -e "${RED}Hủy thao tác${RESET}"
    return
  fi
  
  # Phân tích NodeID (hỗ trợ đơn lẻ hoặc phạm vi)
  local nodeids
  if ! nodeids=$(parse_range "$nodeid_input"); then
    return
  fi
  
  # Kiểm tra NodeID có tồn tại chưa
  local existing_nodeids=()
  if [[ "$node_count" -gt 0 ]]; then
    while IFS= read -r nodeid; do
      existing_nodeids+=("$nodeid")
    done < <(sudo jq -r '.Nodes[].NodeID' "$CONFIG_FILE")
  fi
  
  local nodes_to_add=()
  for nodeid in $nodeids; do
    # Kiểm tra đã tồn tại chưa
    local exists=false
    for existing in "${existing_nodeids[@]}"; do
      if [[ "$nodeid" == "$existing" ]]; then
        echo -e "${YELLOW}Cảnh báo: NodeID $nodeid đã tồn tại, sẽ bỏ qua${RESET}"
        exists=true
        break
      fi
    done
    
    if [[ "$exists" == "false" ]]; then
      nodes_to_add+=("$nodeid")
    fi
  done
  
  if [[ ${#nodes_to_add[@]} -eq 0 ]]; then
    echo -e "${RED}Không có node nào để thêm (tất cả NodeID đều đã tồn tại)${RESET}"
    return
  fi
  
  # Thêm node
  local temp_file=$(mktemp)
  sudo cp "$CONFIG_FILE" "$temp_file"
  
  for nodeid in "${nodes_to_add[@]}"; do
    local new_node=$(jq -n \
      --arg api_host "$api_host" \
      --argjson nodeid "$nodeid" \
      --arg api_key "$api_key" \
      --argjson timeout "$timeout" \
      '{
        "ApiHost": $api_host,
        "NodeID": $nodeid,
        "ApiKey": $api_key,
        "Timeout": $timeout
      }')
    
    sudo jq --argjson node "$new_node" '.Nodes += [$node]' "$temp_file" > "${temp_file}.new"
    mv "${temp_file}.new" "$temp_file"
  done
  
  sudo mv "$temp_file" "$CONFIG_FILE"
  sudo chmod 600 "$CONFIG_FILE"
  
  echo ""
  echo -e "${GREEN}Đã thêm ${#nodes_to_add[@]} node${RESET}"
  echo -e "${GRAY}NodeID: ${nodes_to_add[*]}${RESET}"
  echo -e "${GRAY}ApiHost: $api_host${RESET}"
  
  # Khởi động lại dịch vụ v2node; nếu lỗi vẫn giữ Manager hoạt động để người dùng kiểm tra.
  if ! restart_v2node; then
    echo -e "${YELLOW}Node đã được thêm vào config nhưng service chưa restart thành công.${RESET}"
  fi
}

# Sửa node (có backup)
edit_node() {
  backup_config
  list_nodes
  echo ""
  
  local node_count=$(sudo jq '.Nodes | length' "$CONFIG_FILE")
  if [[ "$node_count" -eq 0 ]]; then
    echo -e "${YELLOW}Không có node nào để sửa${RESET}"
    return
  fi
  
  echo -en "${BOLD}Nhập số thứ tự node cần sửa (1-$node_count): ${RESET}"
  read -r node_index
  
  if [[ -z "$node_index" ]] || ! [[ "$node_index" =~ ^[0-9]+$ ]] || [[ "$node_index" -lt 1 ]] || [[ "$node_index" -gt "$node_count" ]]; then
    echo -e "${RED}Số thứ tự node không hợp lệ${RESET}"
    return
  fi
  
  local array_index=$((node_index - 1))
  
  # Lấy giá trị hiện tại
  local current_node=$(sudo jq ".Nodes[$array_index]" "$CONFIG_FILE")
  local current_nodeid=$(echo "$current_node" | jq -r '.NodeID')
  local current_api_host=$(echo "$current_node" | jq -r '.ApiHost')
  local current_api_key=$(echo "$current_node" | jq -r '.ApiKey')
  local current_timeout=$(echo "$current_node" | jq -r '.Timeout')
  
  echo ""
  echo -e "${GRAY}Cấu hình hiện tại:${RESET}"
  echo -e "  NodeID: $current_nodeid"
  echo -e "  ApiHost: $current_api_host"
  echo -e "  ApiKey: $(mask_api_key "$current_api_key")"
  echo -e "  Timeout: $current_timeout"
  echo ""
  
  # Nhập giá trị mới (Enter giữ nguyên giá trị cũ)
  echo -en "${BOLD}NodeID (mặc định: $current_nodeid): ${RESET}"
  read -r new_nodeid
  new_nodeid=${new_nodeid:-$current_nodeid}
  
  echo -en "${BOLD}API Host (mặc định: $current_api_host): ${RESET}"
  read -r new_api_host
  new_api_host=${new_api_host:-$current_api_host}
  
  echo -en "${BOLD}API Key (Enter = giữ nguyên): ${RESET}"
  read -rs new_api_key
  echo ""
  new_api_key=${new_api_key:-$current_api_key}
  
  echo -en "${BOLD}Timeout (mặc định: $current_timeout): ${RESET}"
  read -r new_timeout
  new_timeout=${new_timeout:-$current_timeout}

  # Xác thực dữ liệu trước khi đưa vào jq --argjson
  if ! [[ "$new_nodeid" =~ ^[1-9][0-9]*$ ]]; then
    echo -e "${RED}NodeID phải là số nguyên dương.${RESET}"
    return
  fi
  if ! [[ "$new_timeout" =~ ^[1-9][0-9]*$ ]]; then
    echo -e "${RED}Timeout phải là số nguyên dương.${RESET}"
    return
  fi
  case "$new_api_host" in
    http://*|https://*) ;;
    *)
      echo -e "${RED}API Host phải bắt đầu bằng http:// hoặc https://${RESET}"
      return
      ;;
  esac
  
  # Kiểm tra NodeID có xung đột với node khác không
  if [[ "$new_nodeid" != "$current_nodeid" ]]; then
    local existing_nodeids=()
    while IFS= read -r nodeid; do
      if [[ "$nodeid" != "$current_nodeid" ]]; then
        existing_nodeids+=("$nodeid")
      fi
    done < <(sudo jq -r '.Nodes[].NodeID' "$CONFIG_FILE")
    
    for existing in "${existing_nodeids[@]}"; do
      if [[ "$new_nodeid" == "$existing" ]]; then
        echo -e "${RED}Lỗi: NodeID $new_nodeid đã được node khác sử dụng${RESET}"
        return
      fi
    done
  fi
  
  # Cập nhật node
  local temp_file=$(mktemp)
  sudo jq \
    --argjson nodeid "$new_nodeid" \
    --arg api_host "$new_api_host" \
    --arg api_key "$new_api_key" \
    --argjson timeout "$new_timeout" \
    ".Nodes[$array_index] = {
      \"NodeID\": \$nodeid,
      \"ApiHost\": \$api_host,
      \"ApiKey\": \$api_key,
      \"Timeout\": \$timeout
    }" "$CONFIG_FILE" > "$temp_file"
  
  sudo mv "$temp_file" "$CONFIG_FILE"
  sudo chmod 600 "$CONFIG_FILE"
  
  echo -e "${GREEN}Node đã được cập nhật${RESET}"
  
  # Khởi động lại dịch vụ v2node; nếu lỗi vẫn giữ Manager hoạt động để người dùng kiểm tra.
  if ! restart_v2node; then
    echo -e "${YELLOW}Node đã được cập nhật trong config nhưng service chưa restart thành công.${RESET}"
  fi
}

# Menu chính
function v2node_menu() {
  while true; do
    echo ""
    echo -e "${BOLD}${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
    echo -e "${BOLD}${CYAN}      Công cụ quản lý V2Node Pro${RESET}"
    echo -e "${BOLD}${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
    echo -e "${GRAY}Config: $CONFIG_FILE${RESET}"
    
    # Hiển thị trạng thái quick
    if check_v2node; then
      echo -e "${GREEN}● V2Node: Đã cài${RESET}"
    else
      echo -e "${RED}○ V2Node: Chưa cài${RESET}"
    fi
    
    echo ""
    echo -e "${BOLD}┌─ Quản lý cài đặt${RESET}"
    echo -e "  ${YELLOW}i${RESET}) Cài đặt/Cài lại V2Node"
    echo -e "  ${YELLOW}u${RESET}) Cài lại/Cập nhật V2node Pro V 2.0.1"
    echo -e "  ${YELLOW}s${RESET}) Xem trạng thái V2Node"
    echo -e "  ${YELLOW}r${RESET}) Khởi động lại V2Node"
    echo ""
    echo -e "${BOLD}┌─ Quản lý Node${RESET}"
    echo -e "  ${YELLOW}1${RESET}) Liệt kê tất cả node"
    echo -e "  ${YELLOW}2${RESET}) Thêm node ${GRAY}(hỗ trợ: 1,3,5 | 1-5 | kết hợp)${RESET}"
    echo -e "  ${YELLOW}3${RESET}) Xóa node ${GRAY}(hỗ trợ phạm vi: 1-5, 96-98)${RESET}"
    echo -e "  ${YELLOW}4${RESET}) Sửa node"
    echo ""
    echo -e "${BOLD}┌─ Tiện ích${RESET}"
    echo -e "  ${YELLOW}5${RESET}) Xem nội dung file config"
    echo -e "  ${YELLOW}b${RESET}) Khôi phục từ backup"
    echo -e "  ${YELLOW}0${RESET}) Thoát"
    echo ""
    echo -en "${BOLD}Lựa chọn ➜ ${RESET}"
    
    read -r choice
    
    case "$choice" in
      i|I)
        install_v2node
        echo ""
        echo -e "${GREEN}Hoàn tất.${RESET} Bấm Enter để tiếp tục..."
        read -r
        ;;
      u|U)
        update_v2node
        echo ""
        echo -e "${GREEN}Hoàn tất.${RESET} Bấm Enter để tiếp tục..."
        read -r
        ;;
      s|S)
        show_v2node_status
        echo ""
        echo -e "${GREEN}Hoàn tất.${RESET} Bấm Enter để tiếp tục..."
        read -r
        ;;
      r|R)
        restart_v2node || true
        echo ""
        echo -e "${GREEN}Hoàn tất.${RESET} Bấm Enter để tiếp tục..."
        read -r
        ;;
      1) 
        list_nodes
        echo ""
        echo -e "${GREEN}Hoàn tất.${RESET} Bấm Enter để tiếp tục..."
        read -r
        ;;
      2) 
        add_node
        echo ""
        echo -e "${GREEN}Hoàn tất.${RESET} Bấm Enter để tiếp tục..."
        read -r
        ;;
      3) 
        delete_node
        echo ""
        echo -e "${GREEN}Hoàn tất.${RESET} Bấm Enter để tiếp tục..."
        read -r
        ;;
      4) 
        edit_node
        echo ""
        echo -e "${GREEN}Hoàn tất.${RESET} Bấm Enter để tiếp tục..."
        read -r
        ;;
      5) 
        echo ""
        echo -e "${BOLD}${CYAN}Nội dung tệp cấu hình:${RESET}"
        jq 'if (.Nodes | type) == "array" then .Nodes |= map(.ApiKey = (if ((.ApiKey // "") | length) <= 4 then "****" elif ((.ApiKey // "") | length) <= 8 then ((.ApiKey // "")[0:2] + "****") else ((.ApiKey // "")[0:4] + "****" + (.ApiKey // "")[-4:]) end)) else . end' "$CONFIG_FILE" 2>/dev/null || echo "Không thể hiển thị config."
        echo ""
        echo -e "${GREEN}Hoàn tất.${RESET} Bấm Enter để tiếp tục..."
        read -r
        ;;
      b|B)
        restore_backup
        echo ""
        echo -e "${GREEN}Hoàn tất.${RESET} Bấm Enter để tiếp tục..."
        read -r
        ;;
      0) 
        echo -e "${GREEN}Tạm biệt!${RESET}"
        return 0
        ;;
      *) 
        echo -e "${RED}Lựa chọn không hợp lệ${RESET}"
        sleep 1
        ;;
    esac
  done
}

# Khôi phục từ backup
restore_backup() {
  echo -e "${BOLD}${CYAN}Khôi phục cấu hình từ backup${RESET}"
  echo ""
  
  if [[ ! -d "$BACKUP_DIR" ]] || [[ -z "$(ls -A "$BACKUP_DIR" 2>/dev/null)" ]]; then
    echo -e "${YELLOW}Không tìm thấy file backup nào${RESET}"
    return
  fi
  
  echo -e "${BOLD}Danh sách backup có sẵn:${RESET}"
  echo ""
  
  local backups=()
  local index=1
  while IFS= read -r backup; do
    backups+=("$backup")
    local size=$(du -h "$backup" 2>/dev/null | cut -f1)
    local date=$(basename "$backup" | sed 's/config_\(.*\)\.json/\1/' | sed 's/_/ /')
    echo -e "  ${YELLOW}$index${RESET}) $date ${GRAY}($size)${RESET}"
    ((index++))
  done < <(ls -t "$BACKUP_DIR"/config_*.json 2>/dev/null)
  
  echo ""
  echo -en "${BOLD}Chọn backup để khôi phục (1-${#backups[@]}) hoặc 0 để hủy: ${RESET}"
  read -r choice
  
  if [[ "$choice" == "0" ]] || [[ -z "$choice" ]]; then
    echo -e "${YELLOW}Hủy khôi phục${RESET}"
    return
  fi
  
  if [[ ! "$choice" =~ ^[0-9]+$ ]] || [[ "$choice" -lt 1 ]] || [[ "$choice" -gt ${#backups[@]} ]]; then
    echo -e "${RED}Lựa chọn không hợp lệ${RESET}"
    return
  fi
  
  local selected_backup="${backups[$((choice-1))]}"
  
  echo -e "${YELLOW}Đang khôi phục từ: $(basename "$selected_backup")${RESET}"
  
  # Backup config hiện tại trước khi khôi phục
  if [[ -f "$CONFIG_FILE" ]]; then
    cp "$CONFIG_FILE" "${CONFIG_FILE}.before_restore"
  fi
  
  cp "$selected_backup" "$CONFIG_FILE"
  chmod 600 "$CONFIG_FILE"
  
  echo -e "${GREEN}✓ Khôi phục file cấu hình thành công.${RESET}"
  echo -e "${GRAY}File cũ đã được lưu tại: ${CONFIG_FILE}.before_restore${RESET}"

  # Áp dụng config vừa khôi phục ngay lập tức
  if restart_v2node; then
    echo -e "${GREEN}✓ Config backup đã được áp dụng cho v2node.${RESET}"
  else
    echo -e "${YELLOW}Config đã được khôi phục nhưng cần kiểm tra lại service v2node.${RESET}"
  fi
}

# Cài đặt trực tiếp bằng CLI: install --api-host ... --node-id ... --api-key ... [--timeout 15]
cli_usage() {
  cat <<'EOF'
Cách dùng:
  bash v2node-pro-manager.sh install --api-host 'https://panel.example.com' --node-id '92' --api-key 'KEY'

Node ID hỗ trợ:
  81
  81,82,83
  81-85
  81-85,90,95-98

Tùy chọn:
  --timeout N    Timeout của node, mặc định 15
EOF
}

cli_install() {
  local api_host="" api_key="" nodeid_input="" timeout="15"
  local nodeids temp_config old_config="" had_config=0
  local txn_dir="" pre_active=0 pre_enabled=0

  shift # bỏ chữ "install"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --api-host)
        [[ $# -ge 2 ]] || { echo -e "${RED}Thiếu giá trị cho --api-host${RESET}"; return 2; }
        api_host="$2"; shift 2 ;;
      --api-key)
        [[ $# -ge 2 ]] || { echo -e "${RED}Thiếu giá trị cho --api-key${RESET}"; return 2; }
        api_key="$2"; shift 2 ;;
      --node-id)
        [[ $# -ge 2 ]] || { echo -e "${RED}Thiếu giá trị cho --node-id${RESET}"; return 2; }
        nodeid_input="$2"; shift 2 ;;
      --timeout)
        [[ $# -ge 2 ]] || { echo -e "${RED}Thiếu giá trị cho --timeout${RESET}"; return 2; }
        timeout="$2"; shift 2 ;;
      -h|--help)
        cli_usage; return 0 ;;
      *)
        echo -e "${RED}Tham số không hỗ trợ: $1${RESET}"
        cli_usage
        return 2 ;;
    esac
  done

  [[ -n "$api_host" ]] || { echo -e "${RED}Thiếu --api-host${RESET}"; return 2; }
  [[ -n "$api_key" ]] || { echo -e "${RED}Thiếu --api-key${RESET}"; return 2; }
  [[ -n "$nodeid_input" ]] || { echo -e "${RED}Thiếu --node-id${RESET}"; return 2; }
  case "$api_host" in
    http://*|https://*) ;;
    *) echo -e "${RED}API Host phải bắt đầu bằng http:// hoặc https://${RESET}"; return 2 ;;
  esac
  [[ "$timeout" =~ ^[1-9][0-9]*$ ]] || { echo -e "${RED}--timeout phải là số nguyên dương.${RESET}"; return 2; }

  if ! nodeids="$(parse_range "$nodeid_input")"; then
    return 2
  fi

  check_jq
  mkdir -p "$(dirname "$CONFIG_FILE")" "$BACKUP_DIR"

  # Tạo config mới ở file tạm trước; không đụng config production nếu JSON chưa hợp lệ.
  temp_config="$(mktemp /tmp/v2node-config.XXXXXX)"
  jq -n --arg host "$api_host" --arg key "$api_key" --argjson timeout "$timeout" \
    --arg ids "$nodeids" '
      {
        Log: {Level:"none", Output:"", Access:"none"},
        Nodes: ($ids | split(" ") | map({ApiHost:$host, NodeID:(tonumber), ApiKey:$key, Timeout:$timeout})),
        PprofPort: 6060
      }' > "$temp_config"
  jq -e '.Nodes | type == "array" and length > 0' "$temp_config" >/dev/null

  # Backup config production để rollback nếu cài/update binary hoặc service thất bại.
  if [[ -f "$CONFIG_FILE" ]]; then
    had_config=1
    old_config="${BACKUP_DIR}/config_before_cli_install_$(date +%Y%m%d_%H%M%S).json"
    cp -a "$CONFIG_FILE" "$old_config"
    chmod 600 "$old_config"
    echo -e "${GRAY}→ Backup config: $old_config${RESET}"
  fi

  install -m 600 "$temp_config" "$CONFIG_FILE"
  rm -f "$temp_config"

  echo -e "${CYAN}V2node Pro V ${V2NODE_VERSION} - CLI install${RESET}"
  echo -e "  ApiHost: ${api_host}"
  echo -e "  ApiKey : $(mask_api_key "$api_key")"
  echo -e "  NodeID : ${nodeids}"
  echo -e "  Timeout: ${timeout}"

  # Snapshot production trước khi thay binary/service để có thể rollback toàn bộ
  # nếu bước kiểm tra cuối cùng thất bại sau khi installer đã trả về thành công.
  txn_dir="$(mktemp -d /tmp/v2node-pro-txn.XXXXXX)"
  [[ -f "$V2NODE_BIN" ]] && cp -a "$V2NODE_BIN" "$txn_dir/v2node"
  [[ -f "$SERVICE_FILE" ]] && cp -a "$SERVICE_FILE" "$txn_dir/v2node.service"
  [[ -f "$DROPIN_FILE" ]] && cp -a "$DROPIN_FILE" "$txn_dir/dropin.conf"
  systemctl is-active --quiet v2node 2>/dev/null && pre_active=1 || true
  systemctl is-enabled --quiet v2node 2>/dev/null && pre_enabled=1 || true

  if ! download_v2node_pro; then
    echo -e "${RED}Cài đặt thất bại. Đang rollback config...${RESET}"
    if [[ "$had_config" -eq 1 && -n "$old_config" && -f "$old_config" ]]; then
      cp -a "$old_config" "$CONFIG_FILE"
      chmod 600 "$CONFIG_FILE"
    else
      rm -f "$CONFIG_FILE"
    fi
    systemctl restart v2node >/dev/null 2>&1 || true
    rm -rf "$txn_dir"
    return 1
  fi

  # Kiểm tra cuối cùng: service phải active, config 600 và runtime nhận GOGC=75.
  if ! systemctl is-active --quiet v2node; then
    echo -e "${RED}Service không active sau cài đặt. Đang rollback toàn bộ transaction...${RESET}"
    if [[ "$had_config" -eq 1 && -n "$old_config" && -f "$old_config" ]]; then
      cp -a "$old_config" "$CONFIG_FILE"
      chmod 600 "$CONFIG_FILE"
    else
      rm -f "$CONFIG_FILE"
    fi
    if [[ -f "$txn_dir/v2node" ]]; then cp -a "$txn_dir/v2node" "$V2NODE_BIN"; else rm -f "$V2NODE_BIN"; fi
    if [[ -f "$txn_dir/v2node.service" ]]; then cp -a "$txn_dir/v2node.service" "$SERVICE_FILE"; else rm -f "$SERVICE_FILE"; fi
    if [[ -f "$txn_dir/dropin.conf" ]]; then
      mkdir -p "$DROPIN_DIR"
      cp -a "$txn_dir/dropin.conf" "$DROPIN_FILE"
    else
      rm -f "$DROPIN_FILE"
    fi
    systemctl daemon-reload >/dev/null 2>&1 || true
    if [[ "$pre_enabled" -eq 1 ]]; then systemctl enable v2node >/dev/null 2>&1 || true; else systemctl disable v2node >/dev/null 2>&1 || true; fi
    if [[ "$pre_active" -eq 1 ]]; then systemctl restart v2node >/dev/null 2>&1 || true; else systemctl stop v2node >/dev/null 2>&1 || true; fi
    rm -rf "$txn_dir"
    return 1
  fi
  chmod 600 "$CONFIG_FILE"
  local pid runtime_gogc=""
  pid="$(systemctl show -p MainPID --value v2node 2>/dev/null || true)"
  if [[ "$pid" =~ ^[1-9][0-9]*$ && -r "/proc/$pid/environ" ]]; then
    runtime_gogc="$(tr '\0' '\n' < "/proc/$pid/environ" | grep '^GOGC=' || true)"
  fi

  echo -e "${GREEN}✓ Cài đặt V2node Pro V ${V2NODE_VERSION} hoàn tất${RESET}"
  echo -e "${GREEN}✓ Service: active${RESET}"
  echo -e "${GREEN}✓ Config: $CONFIG_FILE (chmod 600)${RESET}"
  if [[ "$runtime_gogc" == "GOGC=75" ]]; then
    echo -e "${GREEN}✓ Runtime: GOGC=75${RESET}"
  else
    echo -e "${YELLOW}⚠ Chưa xác nhận được GOGC=75 từ runtime; kiểm tra systemctl cat v2node.${RESET}"
  fi
  rm -rf "$txn_dir"
}

# Hàm chính
main() {
  # Kiểm tra quyền root trước
  check_root
  
  # Hiển thị tiêu đề
  clear
  echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
  echo -e "${BOLD}${CYAN}      V2node Pro V 2.0.1 Manager${RESET}"
  echo -e "${GRAY}      Quản lý V2Node chuyên nghiệp${RESET}"
  echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
  echo ""
  
  # Kiểm tra và cài đặt dependencies
  check_jq
  check_config
  
  # Kiểm tra v2node và đề xuất cài đặt nếu chưa có
  if ! check_v2node; then
    echo -e "${YELLOW}⚠ V2Node chưa được cài đặt trên hệ thống${RESET}"
    echo -en "${BOLD}Bạn có muốn cài đặt ngay không? [Y/n]: ${RESET}"
    read -r install_choice
    if [[ ! "$install_choice" =~ ^[Nn]$ ]]; then
      install_v2node
      echo ""
      echo -e "${GREEN}Nhấn Enter để tiếp tục...${RESET}"
      read -r
    fi
  fi
  
  v2node_menu
}

# Nếu chạy trực tiếp script này
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  check_root
  if [[ "${1:-}" == "install" ]]; then
    cli_install "$@"
  elif [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
    cli_usage
  elif [[ $# -gt 0 ]]; then
    echo -e "${RED}Lệnh không hỗ trợ: ${1}${RESET}"
    cli_usage
    exit 2
  else
    main
  fi
fi

