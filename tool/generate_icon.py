from PIL import Image, ImageDraw
from pathlib import Path

size = 1024
img = Image.new("RGBA", (size, size), (8, 127, 104, 255))
d = ImageDraw.Draw(img)
# Rounded-square inset and simple warehouse/stock mark
d.rounded_rectangle((48, 48, 976, 976), radius=210, fill=(8, 127, 104, 255), outline=(255,255,255,255), width=24)
d.polygon([(220, 430), (512, 230), (804, 430)], fill=(255,255,255,255))
d.rounded_rectangle((260, 420, 764, 790), radius=34, fill=(255,255,255,255))
d.rectangle((330, 500, 430, 790), fill=(8,127,104,255))
d.rectangle((465, 500, 565, 790), fill=(8,127,104,255))
d.rectangle((600, 500, 700, 790), fill=(8,127,104,255))
d.rounded_rectangle((390, 680, 634, 790), radius=20, fill=(255,255,255,255))
d.rectangle((490, 690, 534, 790), fill=(8,127,104,255))
Path("assets").mkdir(exist_ok=True)
img.save("assets/launcher_icon.png")
