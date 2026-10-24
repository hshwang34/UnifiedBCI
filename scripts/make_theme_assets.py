#!/usr/bin/env python3
"""Writes the colour tokens of docs/product/briefs/001-visual-spec.md §1.1 as asset-catalog
colour sets (Any / Dark, each with a High Contrast variant) into App/Assets.xcassets.

Run from the repo root after changing a token: `python3 scripts/make_theme_assets.py`.
Theme.swift reads the sets by name; Tests/ThemeContrastTests.swift reads these same files
to check WCAG contrast, so the assets are the single source of the values."""
import json
import pathlib

# name: (light, dark, high-contrast light, high-contrast dark); "#RRGGBB" or ("#RRGGBB", alpha)
TOKENS = {
    "canvas": ("#F3F6FA", "#0E1116", None, None),
    "surface1": ("#FFFFFF", "#171B22", None, None),
    "surface2": ("#EAEFF5", "#1E232C", None, None),
    "hairline": (("#000000", 0.08), ("#FFFFFF", 0.10), ("#000000", 0.30), ("#FFFFFF", 0.30)),
    "textPrimary": ("#0F1722", "#F2F5F9", None, None),
    "textSecondary": ("#4A5565", "#A7B0BD", "#2F3948", "#C5CCD6"),
    "textTertiary": ("#5D697B", "#8892A2", None, None),
    "accentFill": ("#0A5FCF", "#2A74D6", None, None),
    "accentInk": ("#0A5FCF", "#5AA9FF", "#0847A0", "#8EC5FF"),
    "aurora": ("#1CA7C4", "#58E0D6", None, None),
    "warning": ("#B25E00", "#FFB340", None, None),
    "warningFill": ("#FFF1DA", ("#FFB340", 0.14), None, None),
    "danger": ("#C4261D", "#FF7A70", None, None),
    "positive": ("#1B7F4B", "#5BD08A", None, None),
}


def component(value):
    hexv, alpha = (value, 1.0) if isinstance(value, str) else value
    r, g, b = (int(hexv[i:i + 2], 16) for i in (1, 3, 5))
    return {"color-space": "srgb", "components": {
        "red": f"0x{r:02X}", "green": f"0x{g:02X}", "blue": f"0x{b:02X}", "alpha": f"{alpha:.3f}"}}


def colorset(light, dark, hc_light, hc_dark):
    dark_app = {"appearance": "luminosity", "value": "dark"}
    high = {"appearance": "contrast", "value": "high"}
    colors = [
        {"idiom": "universal", "color": component(light)},
        {"idiom": "universal", "appearances": [dark_app], "color": component(dark)},
        {"idiom": "universal", "appearances": [high], "color": component(hc_light or light)},
        {"idiom": "universal", "appearances": [dark_app, high], "color": component(hc_dark or dark)},
    ]
    return {"colors": colors, "info": {"author": "xcode", "version": 1}}


def main():
    root = pathlib.Path(__file__).resolve().parent.parent / "App" / "Assets.xcassets"
    root.mkdir(parents=True, exist_ok=True)
    (root / "Contents.json").write_text(json.dumps({"info": {"author": "xcode", "version": 1}}, indent=2) + "\n")
    for name, values in TOKENS.items():
        d = root / f"{name}.colorset"
        d.mkdir(exist_ok=True)
        (d / "Contents.json").write_text(json.dumps(colorset(*values), indent=2) + "\n")
    # The app accent is accentFill (the user may still pick a system accent).
    d = root / "AccentColor.colorset"
    d.mkdir(exist_ok=True)
    (d / "Contents.json").write_text(json.dumps(colorset(*TOKENS["accentFill"]), indent=2) + "\n")


if __name__ == "__main__":
    main()
