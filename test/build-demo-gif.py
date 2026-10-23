# 把 test/demo-frames 里的原始帧合成 docs/demo.gif（README 演示用）。
# 用工作区自带 Python（Pillow）。
import os
from PIL import Image, ImageDraw, ImageFont

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
FRAME_DIR = os.path.join(HERE, "demo-frames")
OUT_DIR = os.path.join(ROOT, "docs")
OUT = os.path.join(OUT_DIR, "demo.gif")
os.makedirs(OUT_DIR, exist_ok=True)

TARGET_W = 720
CAPTION_H = 46
FONT_CANDIDATES = [
    r"C:\Windows\Fonts\msyh.ttc",
    r"C:\Windows\Fonts\msyhbd.ttc",
    r"C:\Windows\Fonts\simhei.ttf",
]

captions = {
    0: "mumu_observe：PrintWindow 截图（被遮挡也能截）",
    3: "mumu_app start：启动任意 App",
    4: "mumu_tap：按渲染窗像素点击（光标到位才按）",
    8: "mumu_key back → mumu_app start：回到游戏",
}

font = None
for path in FONT_CANDIDATES:
    if os.path.exists(path):
        try:
            font = ImageFont.truetype(path, 21)
            break
        except Exception:
            pass
if font is None:
    font = ImageFont.load_default()

files = sorted(f for f in os.listdir(FRAME_DIR) if f.startswith("frame-") and f.endswith(".png"))
frames = []
durations = []
total = 0
for name in files:
    idx = int(name.split("-")[1].split(".")[0])
    src = Image.open(os.path.join(FRAME_DIR, name)).convert("RGB")
    w, h = src.size
    target_h = round(h * TARGET_W / w)
    img = src.resize((TARGET_W, target_h), Image.LANCZOS)
    canvas = Image.new("RGB", (TARGET_W, target_h + CAPTION_H), (17, 24, 39))
    canvas.paste(img, (0, 0))
    caption = captions.get(idx)
    if caption:
        draw = ImageDraw.Draw(canvas)
        draw.text((16, target_h + 12), caption, fill=(243, 244, 246), font=font)
    frames.append(canvas.convert("P", palette=Image.ADAPTIVE, colors=128))
    durations.append(700 if caption else 300)
    total += durations[-1]

frames[0].save(
    OUT,
    save_all=True,
    append_images=frames[1:],
    duration=durations,
    loop=0,
    optimize=True,
    disposal=2,
)
print(f"wrote {OUT} ({os.path.getsize(OUT)/1024/1024:.2f} MB, {len(frames)} frames, {total/1000:.1f}s)")
