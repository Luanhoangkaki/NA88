YT MAIN + YT EXIT

Tên:
- VPS MAIN = VPS chạy V2Node/VLESS cho khách.
- VPS EXIT = VPS chỉ làm cổng ra YouTube.

File:
- yt-main.sh
- yt-exit.sh

Cài thành lệnh ngắn:
  install -m 755 yt-main.sh /usr/local/bin/yt-main
  install -m 755 yt-exit.sh /usr/local/bin/yt-exit

Quy trình:
1) EXIT:
   yt-exit install
   yt-exit info

2) MAIN:
   yt-main prepare
   -> nhập Public IP / Public Key / Port của EXIT
   -> MAIN in Public Key.

3) EXIT:
   yt-exit add MAIN-01 <MAIN_PUBLIC_KEY>
   -> EXIT trả MAIN_TUNNEL_IP, ví dụ 10.88.0.2

4) MAIN:
   yt-main activate 10.88.0.2

5) Kiểm tra:
   yt-main test
   yt-main watch 60
   yt-exit status

An toàn:
- MAIN bắt buộc WireGuard Table = off.
- Không sửa /etc/v2node/config.json.
- Backup binary V2Node trước khi thay.
- Nếu default route đổi hoặc V2Node lỗi thì activate rollback.
- EXIT không cần V2Node/XrayR.

Một EXIT phục vụ nhiều MAIN:
  yt-exit add MAIN-SG01 <PUBKEY1>
  yt-exit add MAIN-JP01 <PUBKEY2>
  yt-exit add MAIN-HK01 <PUBKEY3>
  yt-exit list

Binary:
- yt-main ưu tiên /root/v2node-youtube-final
- nếu không có sẽ tải:
  https://github.com/Luanhoangkaki/NA88/releases/latest/download/v2node-youtube-final.gz

Do binary khoảng 104 MB, nên gzip và upload vào GitHub Release:
  gzip -9 -c /root/v2node-youtube-final > /root/v2node-youtube-final.gz

Sau khi upload Git:
EXIT:
  curl -fsSL https://raw.githubusercontent.com/Luanhoangkaki/NA88/main/yt-exit.sh -o /usr/local/bin/yt-exit
  chmod +x /usr/local/bin/yt-exit
  yt-exit install

MAIN:
  curl -fsSL https://raw.githubusercontent.com/Luanhoangkaki/NA88/main/yt-main.sh -o /usr/local/bin/yt-main
  chmod +x /usr/local/bin/yt-main
  yt-main prepare

Lưu ý update V2Node:
- Config V2Node không bị sửa.
- Nhưng binary custom phụ thuộc version source V2Node.
- Khi upstream thay đổi lớn, cần build/release binary custom mới rồi dùng yt-main repair.

V2 FINAL SAFETY / NETWORK
-------------------------
- Preflight phát hiện trùng interface ytwg0.
- MAIN phát hiện xung đột routing table 188 / priority 1000 trước khi cài.
- EXIT phát hiện UDP port WireGuard đã bị chiếm.
- MAIN dùng Table=off, không thay default route.
- MTU mặc định 1380: bảo thủ cho nhiều cloud/VPS path; có thể override:
    YT_WG_MTU=1420 yt-main prepare
    YT_WG_MTU=1420 yt-exit install
  Hai đầu nên dùng cùng MTU.
- PersistentKeepalive=25 ở MAIN.
- EXIT chết sau khi hệ thống đang chạy không làm đổi default route của MAIN; chỉ traffic được V2Node chọn cho YouTube EXIT bị ảnh hưởng.
- Không restart nginx/caddy/database/firewall service.
- MAIN chỉ restart v2node khi activate/repair/rollback/uninstall cần thiết.
- Không flush toàn bộ iptables; EXIT chỉ thêm rule FORWARD/NAT của subnet WireGuard.
- Không có sysctl "tuning" hung hăng (BBR/buffer) để tránh ảnh hưởng dịch vụ khác.

Kiểm thử trước production:
  yt-exit test
  yt-main test
  yt-main watch 60
Sau đó reboot từng VPS một và chạy lại test/status.

V3 REVIEW FIXES
---------------
- Khôi phục ip_forward gốc khi gỡ EXIT.
- EXIT có PostDown để dọn FORWARD/NAT khi service stop/uninstall.
- MAIN/EXIT validate IP, key, port và MTU.
- MAIN route service có ExecStop để dọn table/rule khi stop.
- GitHub Release binary phải có file checksum:
    v2node-youtube-final.gz
    v2node-youtube-final.gz.sha256
- MAIN status phát hiện V2Node binary bị thay sau update upstream.
- repair backup binary hiện tại trước khi ghi custom.
- uninstall không ghi đè một binary upstream mới bằng backup cũ nếu phát hiện V2Node đã được update.

GIỚI HẠN UPDATE
---------------
Không thể đảm bảo một binary custom cũ tương thích với mọi phiên bản V2Node tương lai.
Khi upstream V2Node thay đổi, cần build/release custom binary mới từ đúng source mới.
Script sẽ phát hiện binary drift, nhưng không tự đoán compatibility.

V4 MENU
-------
Chạy không tham số để mở menu ngắn:
  yt-main
  yt-exit

Cập nhật:
  yt-main update       # cập nhật chính script từ Git
  yt-exit update       # cập nhật chính script từ Git
  yt-main update-core  # cập nhật binary YouTube Core + SHA256 + rollback nếu lỗi

Phiên bản:
  yt-main version
  yt-exit version

Menu không chạy nền, không tốn tài nguyên khi thoát.

V4.1 REVIEW
-----------
- Kiểm tra subnet 10.88.x.0/24 có xung đột với mạng/route hiện có trước khi cài.
- MAIN bắt buộc tunnel IP cùng /24 với EXIT.
- EXIT kiểm tra peer MAIN không dùng trùng IP EXIT.
- EXIT cài iproute2 rõ ràng để có ss/ip.
- test kiểm tra WireGuard handshake khi đã có peer.
- repair MAIN không tự ghi đè một V2Node upstream mới bằng custom binary cũ; hãy update-core bằng build tương thích.
- Menu mục Cài không thử activate lại nếu hệ thống đã active.
