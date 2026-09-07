#!/usr/bin/env bash
# Khám máy trước khi dựng luồng livestream — CHỈ ĐỌC, không cài, không sửa gì.
line(){ printf '\n\033[1;33m── %s\033[0m\n' "$1"; }
ok(){ printf '  \033[0;32m✓\033[0m %s\n' "$1"; }
no(){ printf '  \033[0;31m✗\033[0m %s\n' "$1"; }
inf(){ printf '    %s\n' "$1"; }

printf '\033[1m═══ KHÁM VPS TRƯỚC KHI DỰNG LUỒNG LIVE ═══\033[0m\n'
printf 'Thời điểm: %s\n' "$(date '+%d/%m/%Y %H:%M:%S %Z')"

line "MÁY"
inf "Tên máy   : $(hostname)"
inf "Hệ điều hành: $(. /etc/os-release 2>/dev/null && echo "$PRETTY_NAME" || uname -s)"
inf "Nhân CPU  : $(nproc) nhân"
inf "Model CPU : $(grep -m1 'model name' /proc/cpuinfo | cut -d: -f2 | sed 's/^ *//')"
inf "RAM       : $(free -h | awk '/^Mem:/{print $2" tổng, "$7" còn trống"}')"
inf "Đĩa /     : $(df -h / | awk 'NR==2{print $2" tổng, "$4" trống ("$5" đã dùng)"}')"

line "TẢI HIỆN TẠI"
inf "Load average: $(cut -d' ' -f1-3 /proc/loadavg)  (so với $(nproc) nhân)"
inf "CPU nhàn rỗi: $(top -bn1 | awk '/Cpu\(s\)/{print $8"%"}')"
printf '  5 tiến trình ăn CPU nhất:\n'
ps -eo pcpu,pmem,comm --sort=-pcpu | head -6 | tail -5 | awk '{printf "    %5s%%CPU %5s%%RAM  %s\n",$1,$2,$3}'

line "FFMPEG (thứ nung bảng điểm và mã hoá video)"
if command -v ffmpeg >/dev/null 2>&1; then
  ok "đã có: $(ffmpeg -version 2>/dev/null | head -1 | cut -d' ' -f1-3)"
  ffmpeg -hide_banner -encoders 2>/dev/null | grep -q ' libx264' \
    && ok "có libx264 (mã hoá H.264 — bắt buộc)" || no "THIẾU libx264 — phải cài bản đầy đủ"
  ffmpeg -hide_banner -filters 2>/dev/null | grep -q ' overlay' \
    && ok "có filter overlay (chồng bảng điểm)" || no "THIẾU filter overlay"
else
  no "chưa cài ffmpeg (sẽ cài ở bước sau)"
fi

line "CÔNG CỤ KHÁC"
for c in node npm python3 curl git docker; do
  if command -v $c >/dev/null 2>&1; then
    ok "$c $($c --version 2>&1 | head -1 | tr -d '\n' | cut -c1-40)"
  else
    no "$c chưa có"
  fi
done

line "CỔNG ĐANG BỊ CHIẾM"
PORTS=""
if command -v ss >/dev/null 2>&1; then
  PORTS=$(ss -lntu 2>/dev/null)
elif command -v netstat >/dev/null 2>&1; then
  PORTS=$(netstat -lntu 2>/dev/null)
fi
if [ -n "$PORTS" ]; then
  echo "$PORTS" | awk 'NR>1{split($5,a,":"); if(a[length(a)]!="") print a[length(a)]}' \
    | sort -n -u | tr '\n' ' ' | fold -w 68 -s | sed 's/^/    /'
else
  no "không có lệnh ss lẫn netstat"
fi
for p in 1935 8890; do
  printf '  Cổng %s: ' "$p"
  echo "$PORTS" | grep -qE "[:.]$p[[:space:]]" \
    && printf '\033[0;31mĐANG BỊ CHIẾM\033[0m\n' || printf '\033[0;32mtrống\033[0m\n'
done

line "PHẦN MỀM NHẬN LUỒNG (nếu đã có thì dùng lại)"
command -v mediamtx >/dev/null 2>&1 && ok "mediamtx có trong PATH" || inf "mediamtx: không thấy trong PATH"
ls -la /usr/local/bin/mediamtx /opt/mediamtx* /root/mediamtx* 2>/dev/null | sed 's/^/    /'
systemctl list-units --type=service --state=running --no-pager --no-legend 2>/dev/null \
  | awk '{print $1}' | grep -Ei 'mediamtx|nginx|rtmp|srs|node|pm2|face' | sed 's/^/    đang chạy: /'

line "MẠNG"
inf "IP công khai : $(curl -s --max-time 5 ifconfig.me 2>/dev/null || echo 'không lấy được')"
inf "Card mạng    : $(ip -o -4 addr show scope global 2>/dev/null | awk '{print $2" "$4}' | tr '\n' ' ')"
if command -v ufw >/dev/null 2>&1; then
  inf "Tường lửa ufw: $(ufw status 2>/dev/null | head -1)"
fi
printf '  Thử bắn ra Facebook (cổng 443): '
timeout 5 bash -c 'cat < /dev/null > /dev/tcp/live-api-s.facebook.com/443' 2>/dev/null \
  && printf '\033[0;32mthông\033[0m\n' || printf '\033[0;31mkhông thông\033[0m\n'
printf '  Thử bắn ra YouTube (cổng 1935): '
timeout 5 bash -c 'cat < /dev/null > /dev/tcp/a.rtmp.youtube.com/1935' 2>/dev/null \
  && printf '\033[0;32mthông\033[0m\n' || printf '\033[0;31mkhông thông — phải mở cổng ra\033[0m\n'

line "ĐO SỨC MÃ HOÁ THẬT (10 giây, không ảnh hưởng gì đang chạy)"
if command -v ffmpeg >/dev/null 2>&1; then
  for res in 1280x720 1920x1080; do
    spd=$(ffmpeg -hide_banner -f lavfi -i "testsrc2=size=$res:rate=30" -t 10 \
          -c:v libx264 -preset veryfast -b:v 3000k -f null - 2>&1 \
          | tr '\r' '\n' | grep -o 'speed= *[0-9.]*x' | tail -1 | tr -d ' ')
    printf '    %s → %s  (cần ≥1.0x mới chạy nổi thời gian thực)\n' "$res" "${spd:-không đo được}"
  done
else
  inf "bỏ qua vì chưa có ffmpeg — cài xong chạy lại script này"
fi

printf '\n\033[1m═══ XONG — chụp toàn bộ màn hình này gửi lại ═══\033[0m\n\n'
