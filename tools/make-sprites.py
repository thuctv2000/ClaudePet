#!/usr/bin/env python3
"""
make-sprites.py — chuẩn hoá ảnh nhân vật thành frame sprite cho Desktop Pet.

Cho một hoặc nhiều ảnh (HOẶC file GIF động) vào một "state", script sẽ:
  1. Nếu là GIF động -> tự tách thành từng frame và tự đặt fps theo tốc độ GIF.
  2. Đảm bảo có kênh alpha (nền trong suốt):
       - Ảnh đã trong suốt  -> giữ nguyên.
       - Có --chroma HEX    -> biến màu nền đơn sắc đó thành trong suốt (chroma-key).
       - Không có gì         -> giữ nguyên (ảnh sẽ có nền đặc).
  3. Cắt sát viền nội dung (bỏ khoảng trong suốt thừa).
  4. Căn giữa lên khung VUÔNG cùng kích thước cho mọi frame -> nhân vật không "nhảy".
  5. Ghi ra ~/.petmacos/sprites/<state>/<state>_NNN.png (+ clip.json nếu là GIF).

VÍ DỤ
  # Ảnh đã tách nền sẵn (PNG trong suốt):
  python3 tools/make-sprites.py idle ~/Downloads/citlali/*.png

  # Ảnh nền xanh lá (#00FF00), tách nền tự động:
  python3 tools/make-sprites.py click --chroma 00FF00 ~/Downloads/click.jpg

  # Làm mới hẳn thư mục state trước khi thêm:
  python3 tools/make-sprites.py sleep --reset ~/Downloads/sleep.png

TUỲ CHỌN
  --chroma HEX     màu nền cần xoá (vd 00FF00, FFFFFF). Bỏ qua nếu ảnh đã trong suốt.
  --tolerance N    độ sai màu khi chroma-key (mặc định 40, tăng nếu nền không xoá hết).
  --size N         cạnh khung vuông đầu ra (mặc định 512).
  --pad F          lề quanh nhân vật, 0..0.4 (mặc định 0.06).
  --reset          xoá sạch frame cũ trong state trước khi ghi.
"""

import argparse
import os
import sys
from pathlib import Path

try:
    from PIL import Image
except ImportError:
    sys.exit("Thiếu Pillow. Cài bằng: python3 -m pip install Pillow")

STATES = ["idle", "click", "thinking", "working", "talking", "asking", "sleep"]
SPRITES_ROOT = Path.home() / ".petmacos" / "sprites"


def chroma_key(img: Image.Image, hex_color: str, tolerance: int) -> Image.Image:
    """Biến các pixel gần `hex_color` thành trong suốt."""
    hex_color = hex_color.lstrip("#")
    kr, kg, kb = (int(hex_color[i:i + 2], 16) for i in (0, 2, 4))
    img = img.convert("RGBA")
    px = img.load()
    w, h = img.size
    for y in range(h):
        for x in range(w):
            r, g, b, a = px[x, y]
            if abs(r - kr) <= tolerance and abs(g - kg) <= tolerance and abs(b - kb) <= tolerance:
                px[x, y] = (r, g, b, 0)
    return img


def load_frames(src: Path):
    """Trả về (danh sách frame RGBA, fps gợi ý hoặc None).
    Với GIF/ảnh nhiều frame: tách từng frame và suy ra fps theo thời lượng."""
    im = Image.open(src)
    try:
        count = im.n_frames
    except Exception:
        count = 1

    if count <= 1:
        return [im.convert("RGBA")], None

    frames, durations = [], []
    for i in range(count):
        im.seek(i)
        frames.append(im.convert("RGBA"))
        durations.append(im.info.get("duration") or 100)
    avg_ms = sum(durations) / len(durations)
    fps = round(1000.0 / avg_ms, 1) if avg_ms > 0 else None
    return frames, fps


def has_real_alpha(img: Image.Image) -> bool:
    """True nếu ảnh có vùng trong suốt thực sự."""
    if img.mode != "RGBA":
        return False
    alpha = img.getchannel("A")
    return alpha.getextrema()[0] < 250  # có pixel gần như trong suốt


def trim_and_center(img: Image.Image, size: int, pad: float) -> Image.Image:
    """Cắt sát viền alpha rồi dán vào giữa khung vuông trong suốt `size`x`size`."""
    img = img.convert("RGBA")
    bbox = img.getchannel("A").getbbox()
    if bbox:
        img = img.crop(bbox)

    inner = max(1, int(size * (1 - 2 * pad)))
    img.thumbnail((inner, inner), Image.LANCZOS)

    canvas = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    x = (size - img.width) // 2
    y = (size - img.height) // 2
    canvas.paste(img, (x, y), img)
    return canvas


def main() -> None:
    parser = argparse.ArgumentParser(description="Chuẩn hoá ảnh thành sprite frame cho Desktop Pet.")
    parser.add_argument("state", choices=STATES, help="tên state (thư mục đích)")
    parser.add_argument("images", nargs="+", help="đường dẫn ảnh (nhận nhiều file / wildcard)")
    parser.add_argument("--chroma", help="màu nền HEX cần xoá, vd 00FF00")
    parser.add_argument("--tolerance", type=int, default=40, help="độ sai màu chroma-key (mặc định 40)")
    parser.add_argument("--size", type=int, default=512, help="cạnh khung vuông đầu ra (mặc định 512)")
    parser.add_argument("--pad", type=float, default=0.06, help="lề quanh nhân vật 0..0.4 (mặc định 0.06)")
    parser.add_argument("--reset", action="store_true", help="xoá frame cũ trong state trước khi ghi")
    args = parser.parse_args()

    out_dir = SPRITES_ROOT / args.state
    out_dir.mkdir(parents=True, exist_ok=True)

    if args.reset:
        for old in out_dir.glob("*.png"):
            old.unlink()

    start = len(list(out_dir.glob(f"{args.state}_*.png")))
    written = 0
    gif_fps = None

    for path in args.images:
        src = Path(path).expanduser()
        if not src.is_file():
            print(f"  bỏ qua (không thấy file): {src}")
            continue
        try:
            frames, fps = load_frames(src)
        except Exception as exc:
            print(f"  bỏ qua (lỗi mở ảnh): {src} — {exc}")
            continue
        if fps:
            gif_fps = fps

        warned = False
        for img in frames:
            if not has_real_alpha(img):
                if args.chroma:
                    img = chroma_key(img, args.chroma, args.tolerance)
                elif not warned:
                    print(f"  ! {src.name}: nền đặc và không có --chroma → giữ nguyên nền. "
                          f"Nên tách nền trước hoặc dùng --chroma.")
                    warned = True

            frame = trim_and_center(img, args.size, args.pad)
            out = out_dir / f"{args.state}_{start + written:03d}.png"
            frame.save(out)
            written += 1

        label = f"{len(frames)} frame" if len(frames) > 1 else "1 frame"
        print(f"  ✓ {src.name} → {label}")

    # GIF: tự ghi clip.json để phát đúng tốc độ và lặp liên tục.
    if gif_fps:
        config = out_dir / "clip.json"
        config.write_text(f'{{"fps": {gif_fps}, "loop": true}}\n', encoding="utf-8")
        print(f"  ↳ tạo clip.json (fps={gif_fps}, loop=true)")

    print(f"\nXong: ghi {written} frame vào {out_dir}")
    print('Mở app → menu bàn chân → "Tải lại sprites".')


if __name__ == "__main__":
    main()
