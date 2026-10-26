from __future__ import annotations

import io
from pathlib import Path


WIDTH = 1200
HEIGHT = 700
BACKGROUND = "#f7fafc"
PLOT_BACKGROUND = "#ffffff"
GRID = "#dbe4ee"
TEXT = "#172033"
MUTED = "#64748b"
BAR = "#2997e5"
BAR_TOP = "#1677bd"


def _font(size: int, bold: bool = False):
    from PIL import ImageFont

    names = [
        "/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf" if bold else
        "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf",
        "/usr/share/fonts/dejavu/DejaVuSans-Bold.ttf" if bold else
        "/usr/share/fonts/dejavu/DejaVuSans.ttf",
    ]
    for name in names:
        if Path(name).is_file():
            return ImageFont.truetype(name, size=size)
    return ImageFont.load_default()


def _value_text(value: float) -> str:
    if value >= 100:
        return f"{value:.0f}"
    if value >= 10:
        return f"{value:.1f}"
    return f"{value:.2f}"


def render_traffic_chart(
    title: str,
    subtitle: str,
    points: list[dict],
    unit: str,
) -> bytes:
    """Render a Telegram-friendly PNG bar chart using Pillow."""
    try:
        from PIL import Image, ImageDraw
    except ImportError as exc:
        raise RuntimeError("для графиков установите пакет python3-pil") from exc

    image = Image.new("RGB", (WIDTH, HEIGHT), BACKGROUND)
    draw = ImageDraw.Draw(image)
    title_font = _font(42, bold=True)
    subtitle_font = _font(25)
    axis_font = _font(20)
    small_font = _font(17)

    draw.text((70, 42), title, fill=TEXT, font=title_font)
    draw.text((70, 100), subtitle, fill=MUTED, font=subtitle_font)

    left, top, right, bottom = 105, 165, 1145, 590
    draw.rounded_rectangle((60, 145, 1170, 645), radius=24, fill=PLOT_BACKGROUND)

    values = [max(0.0, float(point.get("value") or 0.0)) for point in points]
    maximum = max(values, default=0.0)
    scale_max = maximum * 1.15 if maximum > 0 else 1.0

    for step in range(6):
        ratio = step / 5
        y = bottom - int((bottom - top) * ratio)
        draw.line((left, y, right, y), fill=GRID, width=1)
        label = _value_text(scale_max * ratio)
        bbox = draw.textbbox((0, 0), label, font=small_font)
        draw.text((left - 14 - (bbox[2] - bbox[0]), y - 10), label, fill=MUTED, font=small_font)

    count = max(1, len(points))
    slot = (right - left) / count
    bar_width = max(8, min(48, int(slot * 0.62)))
    for index, point in enumerate(points):
        value = values[index]
        center = left + slot * (index + 0.5)
        height = int((bottom - top) * value / scale_max) if scale_max else 0
        x1 = int(center - bar_width / 2)
        x2 = int(center + bar_width / 2)
        y1 = bottom - height
        if height > 0:
            draw.rounded_rectangle((x1, y1, x2, bottom), radius=min(8, bar_width // 3), fill=BAR)
            draw.line((x1 + 3, y1, x2 - 3, y1), fill=BAR_TOP, width=3)

        if point.get("tick"):
            label = str(point.get("label") or "")
            bbox = draw.textbbox((0, 0), label, font=axis_font)
            draw.text(
                (center - (bbox[2] - bbox[0]) / 2, bottom + 18),
                label,
                fill=MUTED,
                font=axis_font,
            )

    draw.line((left, bottom, right, bottom), fill=MUTED, width=2)
    total = sum(values)
    total_text = f"Итого: {_value_text(total)} {unit}"
    bbox = draw.textbbox((0, 0), total_text, font=subtitle_font)
    draw.text((right - (bbox[2] - bbox[0]), 101), total_text, fill=TEXT, font=subtitle_font)
    output = io.BytesIO()
    image.save(output, format="PNG", optimize=True)
    return output.getvalue()


def render_channel_chart(
    points: list[dict],
    period_title: str,
    capacity_mbit: float,
) -> bytes:
    try:
        from PIL import Image, ImageDraw
    except ImportError as exc:
        raise RuntimeError("для графиков установите пакет python3-pil") from exc

    image = Image.new("RGB", (WIDTH, HEIGHT), BACKGROUND)
    draw = ImageDraw.Draw(image)
    title_font = _font(42, bold=True)
    subtitle_font = _font(24)
    axis_font = _font(18)
    legend_font = _font(21, bold=True)

    draw.text((70, 38), "Загрузка канала VDS", fill=TEXT, font=title_font)
    draw.text((70, 98), f"Период: {period_title} · UTC", fill=MUTED, font=subtitle_font)
    draw.text(
        (850, 100),
        f"Канал: {capacity_mbit:g} Мбит/с",
        fill=MUTED,
        font=axis_font,
    )

    left, top, right, bottom = 105, 175, 1145, 575
    draw.rounded_rectangle((55, 145, 1170, 645), radius=24, fill=PLOT_BACKGROUND)

    if not points:
        draw.text(
            (330, 350),
            "Данных пока нет — первый замер появится через минуту",
            fill=MUTED,
            font=subtitle_font,
        )
    else:
        rx = [max(0.0, float(point.get("rx_mbit") or 0.0)) for point in points]
        tx = [max(0.0, float(point.get("tx_mbit") or 0.0)) for point in points]
        observed = max(rx + tx + [0.0])
        scale_max = max(0.1, observed * 1.2)
        if capacity_mbit > 0 and observed >= capacity_mbit * 0.75:
            scale_max = max(scale_max, capacity_mbit * 1.05)

        for step in range(6):
            ratio = step / 5
            y = bottom - int((bottom - top) * ratio)
            draw.line((left, y, right, y), fill=GRID, width=1)
            label = _value_text(scale_max * ratio)
            bbox = draw.textbbox((0, 0), label, font=axis_font)
            draw.text(
                (left - 14 - (bbox[2] - bbox[0]), y - 10),
                label,
                fill=MUTED,
                font=axis_font,
            )

        count = len(points)
        x_for = lambda index: left + (right - left) * index / max(1, count - 1)
        y_for = lambda value: bottom - (bottom - top) * value / scale_max
        rx_line = [(x_for(i), y_for(value)) for i, value in enumerate(rx)]
        tx_line = [(x_for(i), y_for(value)) for i, value in enumerate(tx)]

        overlay = Image.new("RGBA", (WIDTH, HEIGHT), (255, 255, 255, 0))
        overlay_draw = ImageDraw.Draw(overlay)
        overlay_draw.polygon(
            [(rx_line[0][0], bottom), *rx_line, (rx_line[-1][0], bottom)],
            fill=(41, 151, 229, 55),
        )
        overlay_draw.polygon(
            [(tx_line[0][0], bottom), *tx_line, (tx_line[-1][0], bottom)],
            fill=(242, 145, 54, 45),
        )
        image = Image.alpha_composite(image.convert("RGBA"), overlay).convert("RGB")
        draw = ImageDraw.Draw(image)
        if len(rx_line) == 1:
            draw.ellipse((rx_line[0][0] - 4, rx_line[0][1] - 4, rx_line[0][0] + 4, rx_line[0][1] + 4), fill="#2997e5")
            draw.ellipse((tx_line[0][0] - 4, tx_line[0][1] - 4, tx_line[0][0] + 4, tx_line[0][1] + 4), fill="#f29136")
        else:
            draw.line(rx_line, fill="#2997e5", width=4, joint="curve")
            draw.line(tx_line, fill="#f29136", width=4, joint="curve")

        if capacity_mbit > 0 and capacity_mbit <= scale_max:
            capacity_y = y_for(capacity_mbit)
            draw.line((left, capacity_y, right, capacity_y), fill="#dc3545", width=2)

        tick_count = min(6, count)
        tick_indices = sorted(
            {round(i * (count - 1) / max(1, tick_count - 1)) for i in range(tick_count)}
        )
        long_period = period_title in {"7 дней", "30 дней"}
        for index in tick_indices:
            raw = str(points[index].get("timestamp") or "")
            try:
                parsed = __import__("datetime").datetime.strptime(raw, "%Y-%m-%d %H:%M:%S")
                label = parsed.strftime("%d.%m") if long_period else parsed.strftime("%H:%M")
            except ValueError:
                label = raw[5:16]
            bbox = draw.textbbox((0, 0), label, font=axis_font)
            x = x_for(index)
            draw.text((x - (bbox[2] - bbox[0]) / 2, bottom + 18), label, fill=MUTED, font=axis_font)

    draw.line((left, bottom, right, bottom), fill=MUTED, width=2)
    draw.line((80, 160, 120, 160), fill="#2997e5", width=5)
    draw.text((130, 146), "Приём", fill=TEXT, font=legend_font)
    draw.line((270, 160, 310, 160), fill="#f29136", width=5)
    draw.text((320, 146), "Передача", fill=TEXT, font=legend_font)
    draw.text((1010, 146), "Мбит/с", fill=MUTED, font=legend_font)

    output = io.BytesIO()
    image.save(output, format="PNG", optimize=True)
    return output.getvalue()
