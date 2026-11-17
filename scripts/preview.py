#!/usr/bin/env python3
# SPDX-License-Identifier: MIT-0
"""An approximate picture of a page of the theme, for review on a computer.

  preview.py TWRES PAGE OUT.png [VAR=VALUE ...]

Draws PAGE of a complete /twres tree (ui.xml, portrait.xml, scion.xml) the
way TWRP's GUI would, as far as this script knows how: the page template,
fills, images, texts, buttons, check boxes, list boxes, sliders, in TWRP's
1080x1920 design space, then scaled to the S9's 1440x2960 as TWRP scales.
It is NOT TWRP: fonts are TWRP's own (twres/fonts) but its text layout,
list rows and the console are approximations, and conditions are evaluated
on the variables' default values plus those given. Use it to check layout and
colours; only the phone shows the real thing.
"""
import os
import re
import sys
import xml.etree.ElementTree as ET

from PIL import Image, ImageDraw, ImageFont

W, H = 1080, 1920
OUT_W, OUT_H = 1440, 2960


class Theme:
    def __init__(self, twres, overrides):
        self.dir = twres
        self.roots = [ET.parse(os.path.join(twres, f)).getroot() for f in ("ui.xml", "portrait.xml", "scion.xml")]
        self.vars = {"tw_version": "3.7.0_9-0", "tw_time": "22:30", "tw_battery": "87", "tw_no_cpu_temp": "1",
                     "tw_busy": "0", "tw_simulate_actions": "0", "tw_samsung_navbar": "0", "tw_no_battery_percent": "0",
                     "tw_operation_state": "0", "tw_operation_status": "0", "tw_zip_location": "/sdcard",
                     "tw_storage_display_name": "Internal Storage", "tw_storage_free_size": "0"}
        self.fonts, self.images, self.styles, self.templates, self.pages = {}, {}, {}, {}, {}
        for r in self.roots:
            for v in r.iter("variables"):
                for x in v:
                    self.vars.setdefault(x.get("name"), x.get("value"))
            for res in r.iter("resources"):
                for x in res:
                    if x.tag == "font":
                        self.fonts[x.get("name")] = (x.get("filename"), int(x.get("size")))
                    elif x.tag == "image":
                        self.images[x.get("name")] = x.get("filename")
            for s in r.iter("style"):
                self.styles[s.get("name")] = s
            for t in r.iter("templates"):
                for x in t:
                    self.templates[x.get("name")] = x
            for p in r.iter("page"):
                self.pages[p.get("name")] = p
        for o in overrides:
            k, v = o.split("=", 1)
            self.vars[k] = v

    def sub(self, text):
        for _ in range(4):
            text = re.sub(r"%([A-Za-z0-9_]+)%", lambda m: str(self.vars.get(m.group(1), "")), text)
        text = re.sub(r"\{@[a-z0-9_]+=([^}]*)\}", r"\1", text)
        return text

    def num(self, v, default=0):
        if v is None:
            return default
        v = self.sub(v)
        if v in self.vars:
            v = self.vars[v]
        try:
            return int(float(v))
        except ValueError:
            return default

    def colour(self, c):
        c = self.sub(c or "#000000").lstrip("#")
        if len(c) == 6:
            c += "FF"
        return tuple(int(c[i:i + 2], 16) for i in range(0, 8, 2))

    def font(self, name):
        fn, size = self.fonts.get(name, ("RobotoCondensed-Regular.ttf", 42))
        return ImageFont.truetype(os.path.join(self.dir, "fonts", fn), size)

    def image(self, name):
        fn = self.images.get(name, name)
        return Image.open(os.path.join(self.dir, "images", fn + ".png")).convert("RGBA")

    def cond_ok(self, el):
        conds = list(el.findall("condition")) + [c for cs in el.findall("conditions") for c in cs.findall("condition")]
        for c in conds:
            a = self.vars.get(c.get("var1"), c.get("var1"))
            b = self.sub(c.get("var2", ""))
            op = c.get("op", "=")
            if op == "modified":
                return False
            try:
                fa, fb = float(a), float(b)
            except (TypeError, ValueError):
                fa = fb = None
            ok = {"=": a == b, "!=": a != b,
                  ">": fa is not None and fa > fb, "<": fa is not None and fa < fb}.get(op, True)
            if not ok:
                return False
        return True


def place(x, y, w, h, mode):
    mode = int(mode or 0)
    if mode == 1:
        x -= w
    elif mode == 2:
        y -= h
    elif mode == 3:
        x -= w
        y -= h
    elif mode == 4:
        x -= w // 2
        y -= h // 2
    elif mode == 5:
        x -= w // 2
    return x, y


def draw_el(t, img, d, el):
    if not t.cond_ok(el):
        return
    tag = el.tag
    st = t.styles.get(el.get("style")) if el.get("style") else None

    def get(name):
        x = el.find(name)
        if x is None and st is not None:
            x = st.find(name)
        return x

    pl = get("placement")
    x = t.num(pl.get("x")) if pl is not None else 0
    y = t.num(pl.get("y")) if pl is not None else 0
    w = t.num(pl.get("w")) if pl is not None else 0
    h = t.num(pl.get("h")) if pl is not None else 0
    mode = pl.get("placement") if pl is not None else 0
    if tag == "template":
        for c in t.templates.get(el.get("name"), []):
            draw_el(t, img, d, c)
    elif tag == "background":
        d.rectangle([0, 0, W, H], fill=t.colour(el.get("color")))
    elif tag == "fill":
        d.rectangle([x, y, x + w - 1, y + h - 1], fill=t.colour(el.get("color")))
    elif tag == "image":
        im = get("image")
        if im is not None and im.get("resource"):
            pic = t.image(im.get("resource"))
            px, py = place(x, y, pic.width, pic.height, mode)
            img.alpha_composite(pic, (max(px, 0), max(py, 0)))
    elif tag == "text":
        f = get("font")
        font = t.font(f.get("resource") if f is not None else "font_m")
        col = el.get("color") or (f.get("color") if f is not None else None) or "%text_color%"
        txt = t.sub(el.findtext("text") or "")
        tw, th = d.textbbox((0, 0), txt, font=font)[2:]
        px, py = place(x, y, tw, th, mode)
        d.text((px, py), txt, font=font, fill=t.colour(col))
    elif tag in ("button", "checkbox"):
        im = get("image")
        f = get("font")
        txt = t.sub(el.findtext("text") or "")
        if tag == "checkbox":
            pic = t.image("checkbox_false")
            img.alpha_composite(pic, (x, y))
            font = t.font(f.get("resource") if f is not None else "font_m")
            d.text((x + pic.width + 20, y + (pic.height - font.size) // 2), txt, font=font,
                   fill=t.colour((f.get("color") if f is not None else None) or "%text_color%"))
            return
        if im is not None and im.get("resource"):
            pic = t.image(im.get("resource"))
            px, py = place(x, y, pic.width, pic.height, mode)
            img.alpha_composite(pic, (px, py))
            w, h, x, y = pic.width, pic.height, px, py
        if txt:
            font = t.font(f.get("resource") if f is not None else "font_m")
            tw, th = d.textbbox((0, 0), txt, font=font)[2:]
            d.text((x + (w - tw) // 2, y + (h - th) // 2 - 4), txt, font=font,
                   fill=t.colour((f.get("color") if f is not None else None) or "%text_button_color%"))
    elif tag == "listbox":
        f = get("font")
        font = t.font(f.get("resource") if f is not None else "font_m")
        sep = get("separator")
        rowh = 108
        cy = y
        for item in el.findall("listitem"):
            if not t.cond_ok(item) or cy + rowh > y + h:
                continue
            d.text((x + 24, cy + (rowh - font.size) // 2 - 4), t.sub(item.get("name")), font=font,
                   fill=t.colour((f.get("color") if f is not None else None) or "%text_color%"))
            cy += rowh
            if sep is not None:
                d.rectangle([x, cy, x + w, cy + t.num(sep.get("height"), 2) - 1], fill=t.colour(sep.get("color")))
    elif tag == "slider":
        pic = t.image("slider")
        sx, sy = place(t.num("%center_x%"), t.num("%row23_y%"), pic.width, pic.height, 5)
        img.alpha_composite(pic, (sx, sy))
        img.alpha_composite(t.image("slider_touch"), (sx, sy))
        font = t.font("font_s")
        txt = t.sub(el.findtext("text") or "")
        tw, th = d.textbbox((0, 0), txt, font=font)[2:]
        d.text((sx + (pic.width - tw) // 2 + 100, sy + (pic.height - th) // 2), txt, font=font, fill=t.colour("%text_color%"))
    elif tag in ("fileselector", "console", "terminal"):
        d.rectangle([x, y, x + w, y + h], outline=t.colour("%fileselector_linecolor%"), width=2)
        font = t.font("font_s")
        d.text((x + 24, y + 24), {"fileselector": "(file list)", "console": "(console)", "terminal": "(terminal)"}[tag],
               font=font, fill=t.colour("%scion_mute_color%"))


def main():
    if len(sys.argv) < 4:
        sys.exit(__doc__)
    t = Theme(sys.argv[1], sys.argv[4:])
    page = t.pages[sys.argv[2]]
    img = Image.new("RGBA", (W, H), (0, 0, 0, 255))
    d = ImageDraw.Draw(img)
    for el in page:
        if el.tag != "action":
            draw_el(t, img, d, el)
    img.resize((OUT_W, OUT_H), Image.LANCZOS).convert("RGB").save(sys.argv[3], optimize=True)
    print("preview: %s -> %s" % (sys.argv[2], sys.argv[3]))


if __name__ == "__main__":
    main()
