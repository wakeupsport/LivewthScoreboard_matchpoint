#!/usr/bin/env bash
# Cài phần phát luồng cho livestream cá nhân trên srv1909236.
# Chạy sau khi setup.sh đã dựng xong phần nhận luồng.
set -euo pipefail
DIR=/opt/mplive
c(){ printf '\033[%sm%s\033[0m\n' "$1" "$2"; }
ok(){ printf '  \033[0;32m✓\033[0m %s\n' "$1"; }
inf(){ printf '    %s\n' "$1"; }
die(){ printf '\n\033[0;31m✗ %s\033[0m\n' "$1"; exit 1; }

[ "$(id -u)" -eq 0 ] || die "Phải chạy bằng root."
[ -d "$DIR" ] || die "Chưa có $DIR — chạy setup.sh trước."
c '1' "═══ CÀI PHẦN PHÁT LUỒNG ═══"

c '1;33' "1/4 · Thư viện vẽ ảnh"
if python3 -c "import PIL" 2>/dev/null; then
  ok "Pillow đã có"
else
  inf "đang cài python3-pil…"
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq python3-pil >/dev/null
  python3 -c "import PIL" 2>/dev/null || die "cài Pillow thất bại"
  ok "Pillow xong"
fi

c '1;33' "2/4 · Bộ vẽ bảng điểm"
mkdir -p "$DIR/ovl" "$DIR/rec" "$DIR/log" "$DIR/fonts"
cat > "$DIR/render.py" <<'RENDER_EOF'
#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Đọc điểm từ kho (Realtime Database hoặc Firestore) rồi vẽ bảng điểm
"Broadcast Dark" thành chuỗi ảnh PNG đẩy ra stdout cho ffmpeg nung lên hình.

Chạy độc lập:  python3 render.py --once ra.png    (vẽ một tấm để xem thử)
Chạy cho luồng: python3 render.py | ffmpeg -f image2pipe -i - ...
"""
import argparse, json, os, sys, time, urllib.request, urllib.error
from PIL import Image, ImageDraw, ImageFont

ORANGE = (255, 160, 30, 255)
GOLD   = (212, 168, 67, 255)
TXT    = (244, 244, 246, 255)
DIM    = (154, 154, 166, 255)
LIVE   = (229, 52, 63, 255)
PANEL  = (22, 22, 27, 240)
PANEL2 = (30, 30, 36, 255)
LINE   = (48, 48, 58, 255)
BLUE   = (77, 163, 255, 255)

FONTS = [
    "/opt/mplive/fonts/Manrope-Bold.ttf",
    "/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf",
    "/usr/share/fonts/truetype/liberation/LiberationSans-Bold.ttf",
]

def font(size):
    for p in FONTS:
        if os.path.exists(p):
            try:
                return ImageFont.truetype(p, size)
            except Exception:
                pass
    return ImageFont.load_default()

def txt_w(d, s, f):
    try:
        return d.textbbox((0, 0), s, font=f)[2]
    except Exception:
        return len(s) * f.size // 2

def ell(d, s, f, maxw):
    """Cắt bớt chuỗi cho vừa bề ngang, thêm dấu ba chấm."""
    if txt_w(d, s, f) <= maxw:
        return s
    while s and txt_w(d, s + "…", f) > maxw:
        s = s[:-1]
    return s + "…"

# ---------------- đọc điểm ----------------
class Source:
    def __init__(self, cfg):
        self.kind = cfg.get("kind", "rtdb")
        self.room = cfg.get("room", "default")
        if self.kind == "rtdb":
            self.url = cfg["db"].rstrip("/") + "/rooms/" + self.room + ".json"
        else:
            self.url = ("https://firestore.googleapis.com/v1/projects/"
                        + cfg["pid"] + "/databases/(default)/documents/rooms/"
                        + self.room + "?key=" + cfg["key"])

    def fetch(self):
        req = urllib.request.Request(self.url, headers={"Cache-Control": "no-cache"})
        with urllib.request.urlopen(req, timeout=4) as r:
            raw = r.read().decode("utf-8")
        j = json.loads(raw) if raw.strip() else None
        if j is None:
            return None
        if self.kind == "rtdb":
            return j
        v = (j.get("fields") or {}).get("d", {}).get("stringValue")
        return json.loads(v) if v else None

# ---------------- vẽ ----------------
def draw_board(S, W=760, H=200):
    im = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    d = ImageDraw.Draw(im)

    f_hd1  = font(15)
    f_hd2  = font(12)
    f_br1  = font(15)
    f_br2  = font(10)
    f_name = font(19)
    f_sub  = font(14)
    f_pts  = font(30)
    f_game = font(16)
    f_bdg  = font(13)
    f_srv  = font(12)

    meta = S.get("meta", {})
    cfg  = S.get("cfg", {})
    A, B = S.get("A", {}), S.get("B", {})
    s    = S.get("s", [0, 0])
    g    = S.get("g", [0, 0])
    srv  = S.get("srv", {"t": 0, "n": 2})
    over = bool(S.get("over"))

    BODY_H = H - 30                      # chừa chỗ cho badge dưới
    d.rounded_rectangle([0, 0, W - 1, BODY_H], radius=14, fill=PANEL, outline=LINE, width=1)

    # ----- đầu bảng -----
    HD = 34
    d.rounded_rectangle([1, 1, W - 2, HD], radius=13, fill=(34, 34, 42, 255))
    d.rectangle([1, HD - 12, W - 2, HD], fill=(34, 34, 42, 255))
    d.line([(1, HD), (W - 2, HD)], fill=LINE, width=1)

    x = 14
    if meta.get("live", True):
        lw = txt_w(d, "LIVE", f_hd2) + 26
        d.rounded_rectangle([x, 9, x + lw, 26], radius=4, fill=LIVE)
        d.ellipse([x + 7, 15, x + 13, 21], fill=(255, 255, 255, 255))
        d.text((x + 18, 11), "LIVE", font=f_hd2, fill=(255, 255, 255, 255))
        x += lw + 12

    br1 = (meta.get("b1") or "").upper()
    br2 = (meta.get("b2") or "").upper()
    br_w = max(txt_w(d, br1, f_br1), txt_w(d, br2, f_br2))
    head_max = W - x - br_w - 34

    d.text((x, 6),  ell(d, (meta.get("t1") or "").upper(), f_hd1, head_max), font=f_hd1, fill=TXT)
    d.text((x, 21), ell(d, (meta.get("t2") or "").upper(), f_hd2, head_max), font=f_hd2, fill=DIM)

    if br1:
        d.text((W - 14 - txt_w(d, br1, f_br1), 5), br1, font=f_br1, fill=TXT)
    if br2:
        d.text((W - 14 - txt_w(d, br2, f_br2), 22), br2, font=f_br2, fill=ORANGE)

    # ----- hai hàng đội -----
    order = [1, 0] if S.get("swap") else [0, 1]
    ROW_TOP, ROW_H = HD + 8, 56
    for slot, idx in enumerate(order):
        team = A if idx == 0 else B
        y = ROW_TOP + slot * ROW_H
        serving = (srv.get("t") == idx) and not over

        if serving:
            d.rectangle([0, y + 4, 3, y + ROW_H - 10], fill=ORANGE)

        # avatar tròn: chữ cái đầu
        av_c = ORANGE if idx == 0 else BLUE
        d.ellipse([14, y + 6, 54, y + 46], fill=av_c, outline=(255, 255, 255, 40), width=2)
        ini = (team.get("n1") or "?").strip()[:1].upper()
        d.text((34 - txt_w(d, ini, f_name) // 2, y + 15), ini, font=f_name, fill=(15, 15, 17, 255))

        # tên
        name_x, name_max = 66, W - 66 - 210
        n1 = ell(d, team.get("n1") or "", f_name, name_max)
        n2 = ell(d, team.get("n2") or "", f_sub,  name_max)
        d.text((name_x, y + (9 if n2 else 16)), n1, font=f_name, fill=TXT)
        if n2:
            d.text((name_x, y + 31), n2, font=f_sub, fill=DIM)

        # số người giao (đôi + side-out)
        if serving and cfg.get("doubles", True) and cfg.get("mode") == "sideout":
            d.text((W - 208, y + 18), str(srv.get("n", 2)), font=f_srv, fill=ORANGE)

        # chấm giao bóng
        dot = ORANGE if serving else (58, 58, 68, 255)
        d.ellipse([W - 192, y + 20, W - 180, y + 32], fill=dot)

        # ô số game thắng
        gx = W - 160
        d.rounded_rectangle([gx, y + 12, gx + 30, y + 44], radius=6,
                            fill=(54, 44, 18, 255) if g[idx] > 0 else PANEL2,
                            outline=(GOLD if g[idx] > 0 else LINE), width=1)
        gs = str(g[idx])
        d.text((gx + 15 - txt_w(d, gs, f_game) // 2, y + 18), gs, font=f_game,
               fill=(GOLD if g[idx] > 0 else DIM))

        # ô điểm hiện tại
        px = W - 116
        d.rounded_rectangle([px, y + 8, px + 72, y + 48], radius=8,
                            fill=(ORANGE if serving else PANEL2),
                            outline=(ORANGE if serving else LINE), width=1)
        ps = str(s[idx])
        d.text((px + 36 - txt_w(d, ps, f_pts) // 2, y + 12), ps, font=f_pts,
               fill=((20, 20, 22, 255) if serving else TXT))

        if slot == 0:
            d.line([(12, y + ROW_H - 4), (W - 12, y + ROW_H - 4)], fill=(255, 255, 255, 16), width=1)

    # ----- badge GAME/MATCH POINT -----
    label = badge_text(S)
    if label:
        bw = txt_w(d, label, f_bdg) + 40
        by = BODY_H + 3
        d.polygon([(14, by), (14 + bw, by), (14 + bw - 12, by + 24), (14, by + 24)], fill=GOLD)
        d.text((26, by + 5), label, font=f_bdg, fill=(34, 27, 5, 255))

    return im

def badge_text(S):
    cfg = S.get("cfg", {})
    s, g = S.get("s", [0, 0]), S.get("g", [0, 0])
    srv = S.get("srv", {"t": 0})
    A, B = S.get("A", {}), S.get("B", {})
    if S.get("over"):
        w = A if g[0] > g[1] else B
        return ((w.get("n1") or "") + " THẮNG").upper()
    target  = int(cfg.get("target", 11))
    win2    = bool(cfg.get("winBy2", True))
    cap     = int(cfg.get("cap", 0) or 0)
    best_of = int(cfg.get("bestOf", 3))
    need    = best_of // 2 + 1
    for i in (0, 1):
        if cfg.get("mode") == "sideout" and srv.get("t") != i:
            continue
        me, you = s[i] + 1, s[1 - i]
        ok = (cap and me >= cap) or (me >= target and (not win2 or me - you >= 2))
        if ok:
            who = (A if i == 0 else B).get("n1") or ""
            kind = "MATCH POINT" if g[i] + 1 >= need else "GAME POINT"
            return (kind + " — " + who).upper()
    return ""

BLANK = {"meta": {"t1": "", "t2": "", "b1": "", "b2": "", "live": False},
         "cfg": {}, "A": {"n1": ""}, "B": {"n1": ""},
         "s": [0, 0], "g": [0, 0], "srv": {"t": 0, "n": 2}}

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--conf", default="/opt/mplive/score.json")
    ap.add_argument("--fps", type=float, default=4.0)
    ap.add_argument("--width", type=int, default=760)
    ap.add_argument("--height", type=int, default=200)
    ap.add_argument("--once", metavar="FILE", help="vẽ một tấm rồi thoát")
    a = ap.parse_args()

    with open(a.conf, encoding="utf-8") as f:
        cfg = json.load(f)
    src = Source(cfg)

    state, last_ok, warned = None, 0.0, False
    if a.once:
        try:
            state = src.fetch()
        except Exception as e:
            print("không đọc được điểm: %s" % e, file=sys.stderr)
        draw_board(state or BLANK, a.width, a.height).save(a.once)
        print("đã ghi " + a.once, file=sys.stderr)
        return

    period = 1.0 / a.fps
    out = sys.stdout.buffer
    while True:
        t0 = time.time()
        if t0 - last_ok > 0.45:                 # hỏi điểm ~2 lần/giây
            try:
                new = src.fetch()
                if new:
                    state = new
                last_ok, warned = t0, False
            except Exception as e:
                if not warned:
                    print("mất kết nối kho điểm (%s) — giữ bảng cũ" % e, file=sys.stderr)
                    warned = True
                last_ok = t0
        try:
            draw_board(state or BLANK, a.width, a.height).save(out, format="PNG")
            out.flush()
        except (BrokenPipeError, ValueError):
            break
        time.sleep(max(0.0, period - (time.time() - t0)))

if __name__ == "__main__":
    main()
RENDER_EOF
chmod +x "$DIR/render.py"
ok "đã ghi $DIR/render.py"

c '1;33' "3/4 · Script phát luồng"
cat > "$DIR/live.sh" <<'LIVE_EOF'
#!/usr/bin/env bash
# Nhận luồng từ điện thoại, nung bảng điểm, bắn ra Facebook/YouTube/TikTok
# và ghi một bản MP4 để đưa lên R2.
#
#   live.sh              chạy với cấu hình trong /opt/mplive/live.conf
#   live.sh --test       không bắn đi đâu cả, chỉ ghi ra file để xem thử
#   live.sh --tiktok "rtmp://..."   thêm đích TikTok cho riêng phiên này
set -uo pipefail

DIR=/opt/mplive
CONF=$DIR/live.conf
SCORE=$DIR/score.json
FIFO=$DIR/ovl/fifo
LOG=$DIR/log/live.log

c(){ printf '\033[%sm%s\033[0m\n' "$1" "$2"; }
inf(){ printf '  %s\n' "$1"; }
die(){ c '0;31' "✗ $1"; exit 1; }

TEST=0; TT_EXTRA=""
while [ $# -gt 0 ]; do
  case "$1" in
    --test)   TEST=1 ;;
    --tiktok) shift; TT_EXTRA="${1:-}" ;;
    *) die "tham số lạ: $1" ;;
  esac
  shift
done

[ -f "$CONF" ]  || die "thiếu $CONF"
[ -f "$SCORE" ] || die "thiếu $SCORE (khai báo nguồn điểm)"
# shellcheck disable=SC1090
. "$CONF"
PASS=$(cat "$DIR/publish.pass" 2>/dev/null) || die "thiếu $DIR/publish.pass"

RES="${RES:-1920x1080}"
VBR="${VBR:-4500k}"
ABR="${ABR:-128k}"
FPS="${FPS:-30}"
OVL_W="${OVL_W:-760}"
OVL_H="${OVL_H:-200}"
MARGIN="${MARGIN:-36}"
W="${RES%x*}"; H="${RES#*x}"

command -v ffmpeg >/dev/null || die "chưa có ffmpeg"
python3 -c "import PIL" 2>/dev/null || die "thiếu Pillow. Chạy: apt-get install -y python3-pil"
systemctl is-active --quiet mplive-ingest || die "mplive-ingest chưa chạy. systemctl start mplive-ingest"

mkdir -p "$DIR/rec" "$DIR/log" "$DIR/ovl"
STAMP=$(date +%Y%m%d-%H%M%S)
REC="$DIR/rec/live-$STAMP.mp4"

# ---- gom danh sách đích ----
OUTS=()
if [ "$TEST" = "1" ]; then
  c '1;33' "── CHẾ ĐỘ THỬ: không bắn ra nền tảng nào, chỉ ghi file"
else
  [ -n "${FB_URL:-}" ] && OUTS+=("[f=flv:onfail=ignore]$FB_URL")
  [ -n "${YT_URL:-}" ] && OUTS+=("[f=flv:onfail=ignore]$YT_URL")
  [ -n "$TT_EXTRA"   ] && OUTS+=("[f=flv:onfail=ignore]$TT_EXTRA")
  [ -n "${TT_URL:-}" ] && [ -z "$TT_EXTRA" ] && OUTS+=("[f=flv:onfail=ignore]$TT_URL")
  [ ${#OUTS[@]} -eq 0 ] && die "chưa khai báo đích nào trong $CONF (FB_URL / YT_URL)"
fi
OUTS+=("[f=mp4]$REC")
TEE=$(IFS='|'; echo "${OUTS[*]}")

# ---- dọn dẹp khi dừng ----
RPID=""; FPID=""
cleanup(){
  echo
  c '1;33' "── đang dừng, đợi ffmpeg đóng file cho sạch…"
  [ -n "$FPID" ] && kill -INT "$FPID" 2>/dev/null
  for _ in $(seq 1 20); do kill -0 "$FPID" 2>/dev/null || break; sleep 0.5; done
  kill -0 "$FPID" 2>/dev/null && kill -9 "$FPID" 2>/dev/null
  [ -n "$RPID" ] && kill "$RPID" 2>/dev/null
  rm -f "$FIFO"
  if [ -s "$REC" ]; then
    c '1;33' "── sắp lại MP4 cho trình duyệt phát ngay được…"
    if ffmpeg -nostdin -hide_banner -loglevel error -i "$REC" -c copy \
         -movflags +faststart -y "${REC%.mp4}-web.mp4" 2>/dev/null; then
      mv "${REC%.mp4}-web.mp4" "$REC"
      c '0;32' "✓ bản ghi: $REC ($(du -h "$REC" | cut -f1))"
    else
      c '0;33' "⚠ không sắp lại được, giữ bản thô: $REC"
    fi
  else
    c '0;33' "⚠ không có bản ghi (luồng chưa từng vào?)"
  fi
  exit 0
}
trap cleanup INT TERM

# ---- bảng điểm ----
rm -f "$FIFO"; mkfifo "$FIFO"
python3 "$DIR/render.py" --conf "$SCORE" --fps 4 \
        --width "$OVL_W" --height "$OVL_H" > "$FIFO" 2>>"$LOG" &
RPID=$!
sleep 1
kill -0 "$RPID" 2>/dev/null || die "bộ vẽ bảng điểm chết ngay. Xem: tail $LOG"

c '1;36' "═══ ĐANG PHÁT ═══"
inf "Độ phân giải : $RES @ ${FPS}fps, ${VBR}"
inf "Số đích phát : $([ "$TEST" = 1 ] && echo 'không (chế độ thử)' || echo $(( ${#OUTS[@]} - 1 )))"
inf "Bản ghi      : $REC"
inf "Bảng điểm    : ${OVL_W}x${OVL_H} góc trái dưới"
inf "Nhật ký      : tail -f $LOG"
echo
inf "Điện thoại đẩy luồng vào: rtmp://<IP-máy>:1935/live?user=hieu&pass=<mật khẩu>"
inf "Dừng bằng Ctrl+C — ĐỪNG đóng cửa sổ, nếu không bản ghi sẽ hỏng."
echo

# scale luồng vào cho khít khung, chèn viền đen nếu tỉ lệ lệch, rồi chồng bảng điểm
FILTER="[0:v]scale=${W}:${H}:force_original_aspect_ratio=decrease,\
pad=${W}:${H}:(ow-iw)/2:(oh-ih)/2:black,fps=${FPS},setsar=1[base];\
[base][1:v]overlay=${MARGIN}:H-h-${MARGIN}:eof_action=repeat:format=auto[v]"

ffmpeg -nostdin -hide_banner -loglevel warning -stats \
  -thread_queue_size 1024 -rw_timeout 15000000 \
  -i "rtmp://127.0.0.1:1935/live?user=hieu&pass=$PASS" \
  -thread_queue_size 1024 -f image2pipe -framerate 4 -i "$FIFO" \
  -filter_complex "$FILTER" \
  -map "[v]" -map 0:a? \
  -c:v libx264 -preset veryfast -profile:v high -pix_fmt yuv420p \
  -b:v "$VBR" -maxrate "$VBR" -bufsize "$(( ${VBR%k} * 2 ))k" \
  -g $(( FPS * 2 )) -keyint_min $(( FPS * 2 )) -sc_threshold 0 \
  -c:a aac -b:a "$ABR" -ar 44100 -ac 2 \
  -f tee "$TEE" 2>&1 | tee -a "$LOG" &
FPID=$!
wait $FPID
cleanup
LIVE_EOF
chmod +x "$DIR/live.sh"
ok "đã ghi $DIR/live.sh"

c '1;33' "4/4 · File cấu hình"
if [ -f "$DIR/live.conf" ]; then
  ok "live.conf đã có — giữ nguyên, không ghi đè"
else
  cat > "$DIR/live.conf" <<'CONF_EOF'
# ---- ĐỘ PHÂN GIẢI VÀ CHẤT LƯỢNG ----
RES="1920x1080"
VBR="4500k"
ABR="128k"
FPS="30"

# ---- BẢNG ĐIỂM ----
OVL_W="760"
OVL_H="200"
MARGIN="36"

# ---- ĐÍCH PHÁT ----
# Facebook: lấy ở facebook.com/live/producer, nối server + "/" + khoá
FB_URL=""
# YouTube: lấy ở YouTube Studio > Go Live > tab Stream
YT_URL=""
# TikTok: khoá đổi mỗi phiên nên thường truyền lúc chạy:
#   ./live.sh --tiktok "rtmp://.../xxx"
TT_URL=""
CONF_EOF
  chmod 600 "$DIR/live.conf"
  ok "đã tạo $DIR/live.conf (chưa có đích nào — anh điền vào)"
fi

if [ -f "$DIR/score.json" ]; then
  ok "score.json đã có — giữ nguyên"
else
  cat > "$DIR/score.json" <<'SCORE_EOF'
{
  "_huong_dan": "kind là 'rtdb' hoặc 'fs'. rtdb cần db+room. fs cần pid+key+room.",
  "kind": "rtdb",
  "db": "https://DOI-THANH-LINK-FIREBASE-CUA-ANH.firebasedatabase.app",
  "room": "mp-x7k2"
}
SCORE_EOF
  chmod 600 "$DIR/score.json"
  ok "đã tạo $DIR/score.json (anh sửa lại cho khớp bảng điểm)"
fi

printf '\n'
c '1' "═══ XONG ═══"
printf '  Còn hai việc anh phải điền tay:\n\n'
printf '  1. nano %s/score.json   ← link Firebase và mã phòng, lấy y như trong trang bảng điểm\n' "$DIR"
printf '  2. nano %s/live.conf    ← dán địa chỉ Facebook và YouTube\n\n' "$DIR"
printf '  Xem thử bảng điểm ra sao (không cần phát):\n'
printf '    python3 %s/render.py --conf %s/score.json --once /tmp/thu.png\n\n' "$DIR" "$DIR"
printf '  Chạy thử không bắn đi đâu, chỉ ghi file:\n'
printf '    %s/live.sh --test\n\n' "$DIR"
printf '  Phát thật:\n'
printf '    %s/live.sh\n' "$DIR"
printf '    %s/live.sh --tiktok "rtmp://..."   (thêm TikTok cho riêng phiên đó)\n\n' "$DIR"
