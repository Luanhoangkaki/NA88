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
    "Nodes": []
}
EOF
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
    "  ApiKey: \(.value.ApiKey)\n" +
    "  Timeout: \(.value.Timeout)\n"' "$CONFIG_FILE"
}

# Cài đặt v2node
install_v2node() {
  echo -e "${BOLD}${CYAN}Cài đặt V2Node${RESET}"
  echo ""
  
  if check_v2node; then
    echo -e "${YELLOW}V2Node đã được cài đặt tại: $V2NODE_BIN${RESET}"
    echo -en "${BOLD}Bạn có muốn cài đặt lại không? [y/N]: ${RESET}"
    read -r confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
      echo -e "${GREEN}Hủy cài đặt${RESET}"
      return
    fi
  fi
  
  echo -e "${YELLOW}Đang tải và chạy script cài đặt v2node...${RESET}"
  bash <(curl -Ls https://raw.githubusercontent.com/AZZ-vopp/v2node/master/script/install.sh)
  
  if check_v2node; then
    echo -e "${GREEN}✓ V2Node đã được cài đặt thành công!${RESET}"
  else
    echo -e "${RED}✗ Cài đặt V2Node thất bại${RESET}"
  fi
}

# Cập nhật v2node
update_v2node() {
  echo -e "${BOLD}${CYAN}Cập nhật V2Node${RESET}"
  echo ""
  
  if ! check_v2node; then
    echo -e "${RED}V2Node chưa được cài đặt!${RESET}"
    echo -en "${BOLD}Bạn có muốn cài đặt ngay không? [Y/n]: ${RESET}"
    read -r confirm
    if [[ ! "$confirm" =~ ^[Nn]$ ]]; then
      install_v2node
    fi
    return
  fi
  
  echo -e "${GRAY}Phiên bản hiện tại:${RESET}"
  $V2NODE_BIN version 2>/dev/null || echo "Không xác định được"
  echo ""
  
  echo -e "${YELLOW}Đang cập nhật v2node...${RESET}"
  bash <(curl -Ls https://raw.githubusercontent.com/wyx2685/v2node/refs/heads/main/script/install.sh)
  
  echo ""
  echo -e "${GREEN}✓ Cập nhật hoàn tất${RESET}"
  echo -e "${GRAY}Phiên bản mới:${RESET}"
  $V2NODE_BIN version 2>/dev/null || echo "Không xác định được"
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
  sudo chmod 644 "$CONFIG_FILE"
  
  echo -e "${GREEN}Đã xóa ${#delete_indices[@]} node${RESET}"
  
  # Khởi động lại dịch vụ v2node
  restart_v2node
}

# Phân tích đầu vào phạm vi (ví dụ 1-5)
parse_range() {
  local input="$1"
  local result=()
  
  if [[ "$input" =~ ^[0-9]+-[0-9]+$ ]]; then
    local start=$(echo "$input" | cut -d'-' -f1)
    local end=$(echo "$input" | cut -d'-' -f2)
    
    if [[ "$start" -le "$end" ]]; then
      for ((i=start; i<=end; i++)); do
        result+=($i)
      done
    else
      echo -e "${RED}Lỗi phạm vi: giá trị bắt đầu phải nhỏ hơn hoặc bằng giá trị kết thúc${RESET}" >&2
      return 1
    fi
  elif [[ "$input" =~ ^[0-9]+$ ]]; then
    result+=($input)
  else
    echo -e "${RED}Lỗi định dạng: vui lòng nhập số hoặc phạm vi (ví dụ 1-5)${RESET}" >&2
    return 1
  fi
  
  echo "${result[@]}"
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
      echo -e "  ${GRAY}ApiKey: $api_key${RESET}"
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
      read -r api_key
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
    read -r api_key
    if [[ -z "$api_key" ]]; then
      echo -e "${RED}API Key không được để trống${RESET}"
      return
    fi
    
    echo -en "${BOLD}Timeout (mặc định: 15): ${RESET}"
    read -r timeout_input
    timeout=${timeout_input:-15}
  fi
  
  # Nhập NodeID
  echo ""
  echo -en "${BOLD}NodeID (số đơn lẻ, ví dụ 95, hoặc phạm vi, ví dụ 1-5): ${RESET}"
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
    
    sudo jq ".Nodes += [$new_node]" "$temp_file" > "${temp_file}.new"
    mv "${temp_file}.new" "$temp_file"
  done
  
  sudo mv "$temp_file" "$CONFIG_FILE"
  sudo chmod 644 "$CONFIG_FILE"
  
  echo ""
  echo -e "${GREEN}Đã thêm ${#nodes_to_add[@]} node${RESET}"
  echo -e "${GRAY}NodeID: ${nodes_to_add[*]}${RESET}"
  echo -e "${GRAY}ApiHost: $api_host${RESET}"
  
  # Khởi động lại dịch vụ v2node
  restart_v2node
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
  echo -e "  ApiKey: $current_api_key"
  echo -e "  Timeout: $current_timeout"
  echo ""
  
  # Nhập giá trị mới (Enter giữ nguyên giá trị cũ)
  echo -en "${BOLD}NodeID (mặc định: $current_nodeid): ${RESET}"
  read -r new_nodeid
  new_nodeid=${new_nodeid:-$current_nodeid}
  
  echo -en "${BOLD}API Host (mặc định: $current_api_host): ${RESET}"
  read -r new_api_host
  new_api_host=${new_api_host:-$current_api_host}
  
  echo -en "${BOLD}API Key (mặc định: $current_api_key): ${RESET}"
  read -r new_api_key
  new_api_key=${new_api_key:-$current_api_key}
  
  echo -en "${BOLD}Timeout (mặc định: $current_timeout): ${RESET}"
  read -r new_timeout
  new_timeout=${new_timeout:-$current_timeout}
  
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
  sudo chmod 644 "$CONFIG_FILE"
  
  echo -e "${GREEN}Node đã được cập nhật${RESET}"
  
  # Khởi động lại dịch vụ v2node
  restart_v2node
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
    echo -e "  ${YELLOW}u${RESET}) Cập nhật V2Node lên phiên bản mới nhất"
    echo -e "  ${YELLOW}s${RESET}) Xem trạng thái V2Node"
    echo ""
    echo -e "${BOLD}┌─ Quản lý Node${RESET}"
    echo -e "  ${YELLOW}1${RESET}) Liệt kê tất cả node"
    echo -e "  ${YELLOW}2${RESET}) Thêm node ${GRAY}(hỗ trợ phạm vi: 1-5)${RESET}"
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
        cat "$CONFIG_FILE" | jq . 2>/dev/null || cat "$CONFIG_FILE"
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
  chmod 644 "$CONFIG_FILE"
  
  echo -e "${GREEN}✓ Khôi phục thành công!${RESET}"
  echo -e "${GRAY}File cũ đã được lưu tại: ${CONFIG_FILE}.before_restore${RESET}"
}

# Hàm chính
main() {
  # Kiểm tra quyền root trước
  check_root
  
  # Hiển thị tiêu đề
  clear
  echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
  echo -e "${BOLD}${CYAN}      V2Node Manager Pro v1.0${RESET}"
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
  main
fi

