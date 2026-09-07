#!/usr/bin/env bash
# Dựng hạ tầng nhận luồng cho livestream cá nhân — chạy trên srv1909236.
# KHÔNG đụng nginx, không đụng facesearch, không mở cổng nào ngoài 1935.
set -euo pipefail

DIR=/opt/mplive
MTX_VER=1.9.3
line(){ printf '\n\033[1;33m── %s\033[0m\n' "$1"; }
ok(){   printf '  \033[0;32m✓\033[0m %s\n' "$1"; }
inf(){  printf '    %s\n' "$1"; }
die(){  printf '\n\033[0;31m✗ %s\033[0m\n' "$1"; exit 1; }

[ "$(id -u)" -eq 0 ] || die "Phải chạy bằng root."
printf '\033[1m═══ DỰNG HẠ TẦNG LUỒNG LIVE (srv1909236) ═══\033[0m\n'

line "1/5 · Cài ffmpeg"
if command -v ffmpeg >/dev/null 2>&1; then
  ok "đã có sẵn: $(ffmpeg -version | head -1 | cut -d' ' -f3)"
else
  inf "đang cài, mất chừng một phút…"
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq
  apt-get install -y -qq --no-install-recommends ffmpeg >/dev/null
  ok "xong: $(ffmpeg -version | head -1 | cut -d' ' -f3)"
fi
ffmpeg -hide_banner -encoders 2>/dev/null | grep -q ' libx264' \
  || die "ffmpeg thiếu libx264 — không mã hoá H.264 được."
ok "có libx264 và filter overlay"

line "2/5 · Cài MediaMTX (phần nhận luồng từ điện thoại)"
mkdir -p "$DIR"/{bin,rec,ovl,log}
if [ -x "$DIR/bin/mediamtx" ]; then
  ok "đã có sẵn ở $DIR/bin/mediamtx"
else
  cd /tmp
  URL="https://github.com/bluenviron/mediamtx/releases/download/v${MTX_VER}/mediamtx_v${MTX_VER}_linux_amd64.tar.gz"
  inf "tải $URL"
  curl -fsSL "$URL" -o mtx.tgz || die "tải MediaMTX thất bại."
  tar xzf mtx.tgz mediamtx
  mv mediamtx "$DIR/bin/mediamtx"
  chmod +x "$DIR/bin/mediamtx"
  rm -f mtx.tgz
  ok "đã cài $DIR/bin/mediamtx (v$MTX_VER)"
fi

line "3/5 · Cấu hình — chỉ mở cổng RTMP, có mật khẩu"
if [ -f "$DIR/publish.pass" ]; then
  PASS=$(cat "$DIR/publish.pass")
  ok "dùng lại mật khẩu đã có"
else
  PASS=$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 20)
  printf '%s' "$PASS" > "$DIR/publish.pass"
  chmod 600 "$DIR/publish.pass"
  ok "đã sinh mật khẩu đẩy luồng mới"
fi

cat > "$DIR/mediamtx.yml" <<YML
# Chỉ bật RTMP. Tắt HLS/WebRTC/SRT/API để không mở thêm cổng nào trên máy này.
logLevel: info
logDestinations: [file]
logFile: $DIR/log/mediamtx.log

rtmp: yes
rtmpAddress: :1935
rtmpEncryption: "no"

hls: no
webrtc: no
srt: no
rtsp: no
api: no
metrics: no
pprof: no
playback: no

authMethod: internal
authInternalUsers:
  - user: hieu
    pass: $PASS
    ips: []
    permissions:
      - action: publish
        path: live
  - user: any
    pass:
    ips: ['127.0.0.1', '::1']
    permissions:
      - action: read
        path: live

paths:
  live:
    source: publisher
YML
chmod 600 "$DIR/mediamtx.yml"
ok "ghi $DIR/mediamtx.yml — chỉ cổng 1935, publish cần mật khẩu, đọc chỉ từ máy này"

line "4/5 · Đăng ký dịch vụ chạy nền"
cat > /etc/systemd/system/mplive-ingest.service <<UNIT
[Unit]
Description=MediaMTX - nhan luong RTMP cho livestream ca nhan
After=network.target

[Service]
Type=simple
ExecStart=$DIR/bin/mediamtx $DIR/mediamtx.yml
Restart=always
RestartSec=3
# Chan tren tai nguyen: khong bao gio giành CPU voi facesearch
CPUQuota=40%
MemoryMax=512M
Nice=10

[Install]
WantedBy=multi-user.target
UNIT
systemctl daemon-reload
systemctl enable --now mplive-ingest >/dev/null 2>&1
sleep 2
if systemctl is-active --quiet mplive-ingest; then
  ok "mplive-ingest đang chạy"
else
  die "dịch vụ không lên. Xem: journalctl -u mplive-ingest -n 40"
fi

line "5/5 · Đo sức mã hoá thật trên máy này"
inf "mỗi mức đo 15 giây, số phải ≥1.0x mới theo kịp thời gian thực"
for res in 1280x720 1920x1080; do
  case $res in 1280x720) br=2800k;; *) br=4500k;; esac
  spd=$(ffmpeg -hide_banner -f lavfi -i "testsrc2=size=$res:rate=30" -t 15 \
        -c:v libx264 -preset veryfast -b:v $br -f null - 2>&1 \
        | tr '\r' '\n' | grep -o 'speed= *[0-9.]*x' | tail -1 | tr -d ' ')
  n=$(echo "${spd:-speed=0x}" | tr -dc '0-9.')
  verdict=$(awk -v v="$n" 'BEGIN{
    if(v>=2.5) print "thoải mái, còn nhiều dư địa";
    else if(v>=1.6) print "chạy tốt";
    else if(v>=1.15) print "chạy được nhưng sát nút";
    else print "KHÔNG NÊN dùng mức này"}')
  printf '    %-10s → %-9s %s\n' "$res" "${spd:-đo lỗi}" "$verdict"
done

line "6/6 · Tự kiểm chứng — đẩy thử một luồng vào chính máy rồi đọc lại"
ffmpeg -hide_banner -loglevel error -re -f lavfi -i testsrc2=size=640x360:rate=15 \
  -f lavfi -i sine=frequency=440 -t 12 -c:v libx264 -preset ultrafast -b:v 800k \
  -c:a aac -shortest -f flv "rtmp://127.0.0.1:1935/live?user=hieu&pass=$PASS" \
  >/dev/null 2>&1 & TESTPUB=$!
sleep 4
if timeout 8 ffmpeg -hide_banner -loglevel error -i "rtmp://127.0.0.1:1935/live" \
     -t 2 -c copy -y /tmp/mplive-selftest.mp4 >/dev/null 2>&1 && [ -s /tmp/mplive-selftest.mp4 ]; then
  ok "đẩy vào và đọc ra đều chạy — hạ tầng sẵn sàng"
else
  printf '  \033[0;31m✗\033[0m tự kiểm chứng KHÔNG đạt — xem %s/log/mediamtx.log\n' "$DIR"
fi
wait $TESTPUB 2>/dev/null || true
rm -f /tmp/mplive-selftest.mp4

# Kiểm tra chắc chắn không mở cổng thừa
OPEN=$("$DIR/bin/mediamtx" --help >/dev/null 2>&1; ss -lnt 2>/dev/null | grep -cE ':(8888|8889|8890|9997) ' || true)
[ "${OPEN:-0}" -eq 0 ] && ok "không mở cổng thừa nào (HLS/WebRTC/SRT/API đều tắt)"

IP=$(ip -4 -o addr show scope global 2>/dev/null | awk '{split($4,a,"/"); print a[1]}' | head -1)
printf '\n\033[1m═══ XONG ═══\033[0m\n'
printf '  Dán NGUYÊN dòng này vào ô URL của PRISM (hoặc app RTMP bất kỳ):\n\n'
printf '    \033[1;32mrtmp://%s:1935/live?user=hieu&pass=%s\033[0m\n\n' "${IP:-IP_MAY}" "$PASS"
printf '  Nếu app đòi tách riêng URL và Stream key thì điền:\n'
printf '    URL        : rtmp://%s:1935/\n' "${IP:-IP_MAY}"
printf '    Stream key : live?user=hieu&pass=%s\n' "$PASS"
printf '\n  \033[1;31mDòng trên là chìa khoá vào máy — đừng đăng lên nhóm chat.\033[0m\n'
printf '\n  Xem lại mật khẩu : cat %s/publish.pass\n' "$DIR"
printf '  Xem dịch vụ      : systemctl status mplive-ingest\n'
printf '  Nhật ký          : tail -f %s/log/mediamtx.log\n' "$DIR"
printf '  Gỡ bỏ hoàn toàn  : systemctl disable --now mplive-ingest && rm -rf %s /etc/systemd/system/mplive-ingest.service\n' "$DIR"
printf '\n  Chụp màn hình gửi lại (che dòng mật khẩu) để em chốt độ phân giải.\n\n'
