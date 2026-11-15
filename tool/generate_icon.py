from PIL import Image, ImageDraw, ImageFilter, ImageFont
from pathlib import Path
import math

S = 1024
im = Image.new("RGBA", (S, S))
px = im.load()
for y in range(S):
    for x in range(S):
        t = (x + y) / (2 * S)
        glow = max(0.0, 1.0 - math.sqrt((x-360)**2 + (y-250)**2) / 900)
        px[x, y] = (int(8 + 24*t + 8*glow), int(17 + 18*t + 18*glow), int(43 + 55*t + 22*glow), 255)

for color, bounds, blur in [
    ((112, 75, 255, 75), (80, 70, 780, 780), 105),
    ((0, 205, 220, 50), (340, 300, 1020, 980), 115),
]:
    layer = Image.new("RGBA", (S, S), (0,0,0,0))
    ImageDraw.Draw(layer).ellipse(bounds, fill=color)
    im = Image.alpha_composite(im, layer.filter(ImageFilter.GaussianBlur(blur)))

d = ImageDraw.Draw(im)
d.rounded_rectangle((34, 34, 990, 990), radius=235, outline=(255,255,255,65), width=5)
d.rounded_rectangle((62, 62, 962, 962), radius=205, outline=(120,190,255,100), width=3)
panel = Image.new("RGBA", (S, S), (0,0,0,0))
pd = ImageDraw.Draw(panel)
pd.rounded_rectangle((116, 170, 908, 850), radius=125, fill=(255,255,255,18), outline=(255,255,255,55), width=4)
im = Image.alpha_composite(im, panel)
d = ImageDraw.Draw(im)

font = ImageFont.truetype("/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf", 248)
label = "LOL"
bbox = d.textbbox((0,0), label, font=font, stroke_width=2)
tw, th = bbox[2]-bbox[0], bbox[3]-bbox[1]
d.text(((S-tw)//2, 300-bbox[1]), label, font=font, fill=(255,255,255,255), stroke_width=2, stroke_fill=(190,215,255,150))

gold = (255, 196, 92, 255)
cyan = (71, 220, 224, 255)
d.rounded_rectangle((260, 650, 764, 760), radius=34, fill=(255,255,255,20), outline=(255,255,255,80), width=4)
d.rounded_rectangle((294, 682, 420, 730), radius=14, fill=gold)
d.rounded_rectangle((448, 665, 574, 730), radius=14, fill=cyan)
d.rounded_rectangle((602, 640, 728, 730), radius=14, fill=(166,135,255,255))
d.rounded_rectangle((330, 790, 694, 806), radius=8, fill=(255,255,255,180))
d.ellipse((476, 858, 548, 930), fill=gold)
d.ellipse((496, 878, 528, 910), fill=(15,28,62,255))

Path("assets").mkdir(exist_ok=True)
im.save("assets/launcher_icon.png", optimize=True)
