"""Generate a minimalistic app icon for LiveCanvas."""
from PIL import Image, ImageDraw
import os, subprocess, sys

SIZE = 1024
CENTER = SIZE // 2

img = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
draw = ImageDraw.Draw(img)

# Rounded rectangle background — near-black like the app UI
r = 200  # corner radius
bg_color = (17, 17, 17, 255)  # #111111
draw.rounded_rectangle([40, 40, SIZE - 40, SIZE - 40], radius=r, fill=bg_color)

# Subtle border
border_color = (50, 50, 50, 255)
draw.rounded_rectangle([40, 40, SIZE - 40, SIZE - 40], radius=r, outline=border_color, width=3)

# Inner canvas area — slightly lighter rectangle representing a "frame/canvas"
margin = 180
inner_r = 80
canvas_color = (26, 26, 26, 255)
draw.rounded_rectangle(
    [margin, margin, SIZE - margin, SIZE - margin],
    radius=inner_r, fill=canvas_color
)
draw.rounded_rectangle(
    [margin, margin, SIZE - margin, SIZE - margin],
    radius=inner_r, outline=(196, 154, 108, 80), width=2  # subtle amber border
)

# Play triangle in the center — muted amber accent #C49A6C
amber = (196, 154, 108, 255)
tri_size = 140
cx, cy = CENTER, CENTER
# Equilateral-ish play triangle, shifted right slightly for optical centering
offset = 20
points = [
    (cx - tri_size // 2 + offset, cy - tri_size),
    (cx - tri_size // 2 + offset, cy + tri_size),
    (cx + tri_size + offset, cy),
]
draw.polygon(points, fill=amber)

# Three small horizontal lines below the triangle — representing "wallpaper layers"
line_y_start = cy + tri_size + 60
line_w = 200
line_h = 6
gap = 24
for i, alpha in enumerate([180, 120, 70]):
    w = line_w - i * 40
    y = line_y_start + i * (line_h + gap)
    x0 = cx - w // 2
    draw.rounded_rectangle(
        [x0, y, x0 + w, y + line_h],
        radius=3,
        fill=(196, 154, 108, alpha)
    )

# Save PNG at all required sizes
out_dir = os.path.join(os.path.dirname(__file__), "..", "build", "icon.iconset")
os.makedirs(out_dir, exist_ok=True)

icon_sizes = [
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024),
]

for name, sz in icon_sizes:
    resized = img.resize((sz, sz), Image.LANCZOS)
    resized.save(os.path.join(out_dir, name), "PNG")

print(f"Generated {len(icon_sizes)} icon sizes in {out_dir}")

# Convert to .icns
icns_path = os.path.join(os.path.dirname(__file__), "..", "build", "AppIcon.icns")
subprocess.run(["iconutil", "-c", "icns", out_dir, "-o", icns_path], check=True)
print(f"Created {icns_path}")
