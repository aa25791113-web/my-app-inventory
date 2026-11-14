from PIL import Image, ImageDraw, ImageFilter
from pathlib import Path
import math

S = 1024
base = Image.new("RGB", (S, S))
pixels = base.load()
for y in range(S):
    for x in range(S):
        dx, dy = x - S * .48, y - S * .43
        glow = max(0.0, 1.0 - math.sqrt(dx*dx + dy*dy) / 820)
        pixels[x, y] = (
            int(5 + 4 * glow),
            int(23 + 31 * glow),
            int(39 + 40 * glow),
        )
im = base.convert("RGBA")
glow = Image.new("RGBA", (S, S), (0, 0, 0, 0))
gd = ImageDraw.Draw(glow)
gd.ellipse((100, 80, 930, 900), fill=(0, 205, 210, 35))
glow = glow.filter(ImageFilter.GaussianBlur(95))
im = Image.alpha_composite(im, glow)
d = ImageDraw.Draw(im)
d.rounded_rectangle((35, 35, 989, 989), radius=225, outline=(0, 210, 220, 220), width=17)
d.rounded_rectangle((62, 62, 962, 962), radius=200, outline=(255, 190, 75, 170), width=5)

# Rising analytics bars
for x, top, w in [(650, 350, 92), (765, 245, 92), (880, 145, 92)]:
    d.rounded_rectangle((x, top, x+w, 690), radius=20, fill=(0, 190, 205, 235), outline=(125, 245, 245, 255), width=7)

# Metallic gold A and cyan L monogram
gold = (255, 195, 85, 255)
gold_light = (255, 230, 165, 255)
cyan = (0, 205, 220, 255)
d.polygon([(170, 690), (365, 230), (510, 230), (685, 690), (565, 690), (445, 390), (285, 690)], fill=gold, outline=gold_light)
d.polygon([(355, 570), (500, 570), (545, 670), (315, 670)], fill=(7, 35, 49, 255))
d.polygon([(555, 520), (665, 520), (665, 790), (925, 790), (925, 895), (555, 895)], fill=cyan, outline=(140, 250, 250, 255))
# Product box
d.rounded_rectangle((150, 690, 440, 905), radius=22, fill=(235, 164, 50, 255), outline=(255, 225, 160, 255), width=9)
d.polygon([(150, 690), (290, 625), (505, 690), (440, 745)], fill=(255, 205, 105, 255), outline=(255, 235, 185, 255))
d.line((290, 630, 290, 905), fill=(8, 48, 61, 255), width=17)
d.line((355, 790, 395, 830, 465, 750), fill=(5, 43, 55, 255), width=25)
# Gold orbit sweep
d.arc((70, 245, 970, 960), start=198, end=344, fill=(255, 204, 103, 255), width=27)
d.ellipse((477, 920, 545, 988), fill=(255, 196, 78, 230))
Path("assets").mkdir(exist_ok=True)
im.convert("RGB").save("assets/launcher_icon.png", quality=95)
