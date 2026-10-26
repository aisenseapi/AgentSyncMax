from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter


SIZE = 512
ROOT = Path(__file__).resolve().parents[1]
ICON_DIR = ROOT / "src-tauri" / "icons"


def rounded_background() -> Image.Image:
    image = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
    pixels = image.load()
    for y in range(SIZE):
        ratio = y / (SIZE - 1)
        color = (
            round(20 + (7 - 20) * ratio),
            round(42 + (16 - 42) * ratio),
            round(61 + (24 - 61) * ratio),
            255,
        )
        for x in range(SIZE):
            pixels[x, y] = color

    mask = Image.new("L", (SIZE, SIZE), 0)
    ImageDraw.Draw(mask).rounded_rectangle((20, 20, 492, 492), radius=112, fill=255)
    image.putalpha(mask)
    draw = ImageDraw.Draw(image)
    draw.rounded_rectangle((28, 28, 484, 484), radius=104, outline=(49, 83, 106, 255), width=14)
    return image


def build_icon() -> Image.Image:
    image = rounded_background()
    glow = Image.new("RGBA", image.size, (0, 0, 0, 0))
    glow_draw = ImageDraw.Draw(glow)
    points = [(256, 142), (142, 356), (370, 356), (256, 142)]
    glow_draw.line(points, fill=(65, 217, 255, 185), width=28, joint="curve")
    for x, y in points[:3]:
        glow_draw.ellipse((x - 46, y - 46, x + 46, y + 46), outline=(65, 217, 255, 230), width=18)
    blurred = glow.filter(ImageFilter.GaussianBlur(18))
    image.alpha_composite(blurred)

    draw = ImageDraw.Draw(image)
    draw.line(points, fill=(76, 183, 255, 255), width=24, joint="curve")
    for x, y in points[:3]:
        draw.ellipse((x - 44, y - 44, x + 44, y + 44), fill=(8, 16, 24, 255), outline=(89, 221, 255, 255), width=18)
        draw.ellipse((x - 12, y - 12, x + 12, y + 12), fill=(234, 250, 255, 255))
    return image


def main() -> None:
    ICON_DIR.mkdir(parents=True, exist_ok=True)
    icon = build_icon()
    icon.save(ICON_DIR / "icon.png")
    icon.save(
        ICON_DIR / "icon.ico",
        format="ICO",
        sizes=[(16, 16), (24, 24), (32, 32), (48, 48), (64, 64), (128, 128), (256, 256)],
    )


if __name__ == "__main__":
    main()
