#!/usr/bin/env python3
# SPDX-License-Identifier: MIT-0
"""Scion's theme for TWRP 3.7.0's GUI, made at build time from the stock theme.

TWRP's GUI is drawn from /twres in the ramdisk: ui.xml (resources, variables,
templates) includes portrait.xml (every page), splash.xml is the splash screen,
images/ the PNGs. This script reads the stock files (out of the stock image's
ramdisk, never committed here) and writes the files that change:

  ui.xml        colours, the header, theme details, includes scion.xml,
                and holds scion.xml's variables
  portrait.xml  TeamWin's home page renamed twrp_home (Scion's home, in
                scion.xml, is main2 now); Install Image shown only with
                Scion's advanced switch on; the rest unchanged
  splash.xml    replaced by theme/splash.xml
  scion.xml     theme/scion.xml: Scion's home page and pages
  images/       logo.png and splashlogo.png rendered from theme/art/scion-logo.svg;
                TeamWin's other PNGs recoloured (blue accent -> Scion green,
                grey -> Scion's slate), shapes unchanged

Every edit looks for its anchor and stops if the anchor is not there exactly
once, so a different stock theme fails here instead of producing a broken GUI.

  theme.py apply STOCK_TWRES OUT_DIR THEME_DIR   write the changed files to OUT_DIR
  theme.py lint TWRES                              check a complete /twres tree
"""
import os
import re
import shutil
import subprocess
import sys
import xml.etree.ElementTree as ET

# Colours of scion-project.github.io's dark scheme (style.css).
COLOURS = {
    "background_color": "#0B0E12",
    "accent_color": "#4CC47F",
    "accent_color_semitransparent": "#4CC47F30",
    "text_color": "#E6EBF1",
    "text_button_color": "#E6EBF1",
    "text_success_color": "#9BE15D",
    "text_fail_color": "#FF6B6B",
    "highlight_color": "#4CC47F40",
    "caps_highlight_color": "#2F3A4780",
    "warning": "#F5CF7A",
    "error": "#FF6B6B",
    "highlight": "#4CC47F",
    "fileselector_linecolor": "#2F3A47",
    "fileselector_highlight_color": "#232C37",
}
NEW_VARIABLES = {
    "scion_header_color": "#131920",
    "scion_line_color": "#2F3A47",
    "scion_mute_color": "#A3AFBD",
    "scion_warn_color": "#F5CF7A",
}
ACCENT_RGB = (0x4C, 0xC4, 0x7F)
SURFACE_RGB = (0x23, 0x2C, 0x37)     # buttons, tabs, slider track, keys
ICON_RGB = (0xA3, 0xAF, 0xBD)        # navigation and list icons
STOCK_ACCENTS = [(0, 144, 202), (3, 169, 244), (0, 149, 213)]
STOCK_GREYS = [(97, 97, 97), (91, 91, 91), (106, 106, 106), (98, 98, 98), (92, 92, 92), (90, 90, 90), (153, 153, 153)]
SURFACES = {"main_button.png", "main_button_half_height.png", "main_button_half_height_full_width.png",
            "tab_3.png", "tab_4.png", "slider.png", "progress_empty.png", "backspace.png", "shift.png",
            "shift_fill.png", "space.png", "enter.png"}
REPLACED_IMAGES = {"logo.png", "splashlogo.png"}
# Pages the stock portrait.xml names but does not define (TeamWin's, harmless:
# the button that leads there is for devices that partition an SD card).
STOCK_DANGLING = {"partsdcardaction"}


def once(text, old, new, what):
    n = text.count(old)
    if n != 1:
        sys.exit("theme.py: %s: anchor found %d times, expected once:\n%s" % (what, n, old))
    return text.replace(old, new)


def edit_ui(text):
    text = once(text, "<title>Backup Naowz</title>", "<title>Scion</title>", "ui.xml title")
    text = once(text, "<description>Default basic theme</description>",
                "<description>Scion recovery: TeamWin's theme, Scion's colours and pages</description>",
                "ui.xml description")
    text = once(text, '<xmlfile name="portrait.xml"/>',
                '<xmlfile name="portrait.xml"/>\n\t\t<xmlfile name="scion.xml"/>', "ui.xml include")
    for name, value in COLOURS.items():
        pat = re.compile(r'(<variable name="%s" value=")[^"]*(")' % re.escape(name))
        text, n = pat.subn(lambda m: m.group(1) + value + m.group(2), text)
        if n != 1:
            sys.exit("theme.py: ui.xml variable %s found %d times" % (name, n))
    extra = "".join('\t\t<variable name="%s" value="%s"/>\n' % kv for kv in NEW_VARIABLES.items())
    text = once(text, "\t</variables>", extra + "\t</variables>", "ui.xml variables end")
    # The header: slate instead of the accent colour, a thin accent line under it.
    old = ('\t\t\t<fill color="%accent_color%">\n'
           '\t\t\t\t<placement x="0" y="0" w="%screen_width%" h="%header_height%"/>\n'
           '\t\t\t</fill>\n')
    new = ('\t\t\t<fill color="%scion_header_color%">\n'
           '\t\t\t\t<placement x="0" y="0" w="%screen_width%" h="%header_height%"/>\n'
           '\t\t\t</fill>\n\n'
           '\t\t\t<fill color="%accent_color%">\n'
           '\t\t\t\t<placement x="0" y="%header_height%" w="%screen_width%" h="6"/>\n'
           '\t\t\t</fill>\n')
    return once(text, old, new, "ui.xml page template header")


def edit_portrait(text):
    text = once(text, '<page name="main2">', '<page name="twrp_home">', "portrait.xml main2")
    # TWRP's Install Image (flash any image partition): only with Scion's
    # advanced switch on (Scion settings). fstab.py leaves BOOT the only
    # partition it lists.
    old = ('\t\t\t<button style="main_button_half_height">\n'
           '\t\t\t\t<condition var1="tw_selectimage" var2="0"/>\n'
           '\t\t\t\t<placement x="%center_x%" y="%row21a_y%"/>\n'
           '\t\t\t\t<text>{@install_image_btn=Install Image}</text>\n')
    new = old.replace('var2="0"/>\n', 'var2="0"/>\n\t\t\t\t<condition var1="tw_scion_advanced" var2="1"/>\n', 1)
    return once(text, old, new, "portrait.xml Install Image button")


def recolour(src, dst, name):
    from PIL import Image
    im = Image.open(src).convert("RGBA")
    px = im.load()
    target_grey = SURFACE_RGB if name in SURFACES else ICON_RGB

    def near(c, cols, d=24):
        return any(abs(c[0] - r) + abs(c[1] - g) + abs(c[2] - b) <= d for r, g, b in cols)

    changed = 0
    for y in range(im.height):
        for x in range(im.width):
            r, g, b, a = px[x, y]
            if a == 0:
                continue
            if near((r, g, b), STOCK_ACCENTS, 40):
                px[x, y] = ACCENT_RGB + (a,)
                changed += 1
            elif near((r, g, b), STOCK_GREYS):
                px[x, y] = target_grey + (a,)
                changed += 1
    if changed:
        im.save(dst, optimize=True)
    return changed


def render_logo(theme_dir, out_images):
    svg = os.path.join(theme_dir, "art", "scion-logo.svg")
    body = open(svg).read()
    inner = body[body.index(">", body.index("<svg")) + 1: body.rindex("</svg>")]
    # Header icon: 184x256 like TeamWin's logo.png, the mark 136 px square in
    # the 184 px below the 72 px status bar.
    header = ('<svg xmlns="http://www.w3.org/2000/svg" width="184" height="256" viewBox="0 0 184 256">'
              '<g transform="translate(24 96) scale(0.265625)">%s</g></svg>' % inner)
    tmp = os.path.join(out_images, ".header.svg")
    open(tmp, "w").write(header)
    for args in ((tmp, "logo.png", 184, 256), (svg, "splashlogo.png", 560, 560)):
        subprocess.run(["rsvg-convert", "-w", str(args[2]), "-h", str(args[3]), "-o",
                        os.path.join(out_images, args[1]), args[0]], check=True)
    os.remove(tmp)


def split_variables(scion):
    """scion.xml's <variables> block, moved into ui.xml's: TWRP certainly reads
    variables there, and the include then carries pages only."""
    a = scion.index("\t<variables>\n")
    b = scion.index("\t</variables>\n") + len("\t</variables>\n")
    block = scion[a:b]
    lines = [x for x in block.splitlines()[1:-1] if x.strip()]
    return scion[:a] + scion[b:].lstrip("\n"), "".join("\t" + x.strip().join(["\t", "\n"]) for x in lines)


def apply(stock, out, theme_dir):
    os.makedirs(os.path.join(out, "images"), exist_ok=True)
    scion, scion_vars = split_variables(open(os.path.join(theme_dir, "scion.xml")).read())
    ui = edit_ui(open(os.path.join(stock, "ui.xml")).read())
    ui = once(ui, "\t</variables>", scion_vars + "\t</variables>", "ui.xml variables end (scion.xml's)")
    open(os.path.join(out, "ui.xml"), "w").write(ui)
    pt = open(os.path.join(stock, "portrait.xml")).read()
    open(os.path.join(out, "portrait.xml"), "w").write(edit_portrait(pt))
    shutil.copy(os.path.join(theme_dir, "splash.xml"), os.path.join(out, "splash.xml"))
    open(os.path.join(out, "scion.xml"), "w").write(scion)
    render_logo(theme_dir, os.path.join(out, "images"))
    for f in sorted(os.listdir(os.path.join(stock, "images"))):
        if f.endswith(".png") and f not in REPLACED_IMAGES:
            recolour(os.path.join(stock, "images", f), os.path.join(out, "images", f), f)
    for root, _, files in os.walk(out):
        for f in sorted(files):
            p = os.path.join(root, f)
            print("theme: %s" % os.path.relpath(p, out))


# ---- lint ---------------------------------------------------------------

ACTIONS = {"reboot", "home", "key", "page", "reload", "readBackup", "set", "clear", "mount", "unmount",
           "umount", "restoredefaultsettings", "copylog", "compute", "addsubtract", "setguitimezone",
           "overlay", "queuezip", "cancelzip", "queueclear", "sleep", "sleepcounter", "appenddatetobackupname",
           "generatebackupname", "checkpartitionlist", "getpartitiondetails", "screenshot", "setbrightness",
           "fileexists", "killterminal", "checkbackupname", "adbsideloadcancel", "fixsu", "startmtp",
           "stopmtp", "cancelbackup", "checkpartitionlifetimewrites", "mountsystemtoggle", "setlanguage",
           "checkforapp", "togglebacklight", "enableadb", "enablefastboot", "changeterminal", "unmapsuperdevices",
           "flash", "wipe", "refreshsizes", "nandroid", "fixcontexts", "fixpermissions", "dd", "partitionsd",
           "cmd", "terminalcommand", "reinjecttwrp", "decrypt", "adbsideload", "openrecoveryscript",
           "installsu", "decrypt_backup", "repair", "resize", "changefilesystem", "flashimage", "twcmd",
           "setbootslot", "installapp", "uninstalltwrpsystemapp", "repackimage", "fixabrecoverybootloop",
           "editramdisk", "flashramdisk", "flashkernel", "htcdumlockrestoreboot", "htcdumlockreflashrecovery",
           "editfile", "%tw_action%", "%tw_action2%", "%tw_cancel_action%", "wipe_crypto_key"}


def lint(twres):
    errors = []
    trees = {}
    for f in ("ui.xml", "portrait.xml", "scion.xml", "splash.xml"):
        p = os.path.join(twres, f)
        try:
            trees[f] = ET.parse(p).getroot()
        except ET.ParseError as e:
            errors.append("%s: not well-formed: %s" % (f, e))
    if errors:
        return errors
    main = [trees["ui.xml"], trees["portrait.xml"], trees["scion.xml"]]
    pages, styles, templates, resources, variables = {}, set(), set(), set(), set()
    for root in main:
        for p in root.iter("page"):
            n = p.get("name")
            if n in pages:
                errors.append("page %s defined twice" % n)
            pages[n] = p
        styles |= {s.get("name") for s in root.iter("style") if s.get("name")}
        for t in root.iter("templates"):
            templates |= {x.get("name") for x in t if x.tag == "template"}
        for r in root.iter("resources"):
            resources |= {x.get("name") for x in r}
        for v in root.iter("variables"):
            variables |= {x.get("name") for x in v}
    images = os.listdir(os.path.join(twres, "images"))
    for r in trees["ui.xml"].iter("resources"):
        for x in r:
            fn = x.get("filename")
            if x.tag == "image" and fn + ".png" not in images and fn not in images:
                errors.append("image resource %s: no images/%s.png" % (x.get("name"), fn))
    for root, fname in ((trees["portrait.xml"], "portrait.xml"), (trees["scion.xml"], "scion.xml")):
        for el in root.iter():
            if el.get("style") and el.get("style") not in styles:
                errors.append("%s: unknown style %s" % (fname, el.get("style")))
            if el.tag == "template" and el.get("name") and el.get("name") not in templates and \
                    not any(el is x for t in root.iter("templates") for x in t):
                errors.append("%s: unknown template %s" % (fname, el.get("name")))
            if el.tag == "action" and el.get("function"):
                fn = el.get("function")
                if fn not in ACTIONS:
                    errors.append("%s: unknown action function %s" % (fname, fn))
                arg = (el.text or "").strip()
                if fn in ("page",) and "%" not in arg and arg not in pages and arg not in STOCK_DANGLING:
                    errors.append("%s: action page -> missing page %s" % (fname, arg))
                if fn == "overlay" and arg and "%" not in arg and arg not in pages:
                    errors.append("%s: overlay -> missing page %s" % (fname, arg))
                if fn == "set" and "=" in arg:
                    k, v = arg.split("=", 1)
                    if k in ("tw_clear_destination", "tw_back") and "%" not in v and v not in pages:
                        errors.append("%s: %s=%s: no such page" % (fname, k, v))
            for res_attr in ("resource",):
                rv = el.get(res_attr)
                if rv and el.tag in ("image", "font") and "%" not in rv and rv not in resources:
                    errors.append("%s: unknown resource %s" % (fname, rv))
            for attr in ("x", "y", "w", "h"):
                v = el.get(attr) if el.tag == "placement" else None
                if v:
                    for name in re.findall(r"%([a-z0-9_]+)%", v):
                        if name not in variables:
                            errors.append("%s: placement uses undefined variable %s" % (fname, name))
    if "main2" not in pages or "main" not in pages:
        errors.append("main/main2 pages missing")
    # The splash file is a separate package: its own resources only.
    sp = trees["splash.xml"]
    sres = {x.get("name") for r in sp.iter("resources") for x in r}
    svars = {x.get("name") for v in sp.iter("variables") for x in v}
    for el in sp.iter():
        rv = el.get("resource")
        if rv and rv not in sres:
            errors.append("splash.xml: unknown resource %s" % rv)
        for a in ("color", "x", "y", "w", "h"):
            for name in re.findall(r"%([a-z0-9_]+)%", el.get(a) or ""):
                if name not in svars and not name.startswith("tw_"):
                    errors.append("splash.xml: undefined variable %s" % name)
    if not any(p.get("name") == "splash" for p in sp.iter("page")):
        errors.append("splash.xml: no splash page")
    for x in sp.iter("image"):
        fn = x.get("filename")
        if fn and fn + ".png" not in images:
            errors.append("splash.xml: no images/%s.png" % fn)
    return errors


def main():
    if len(sys.argv) == 5 and sys.argv[1] == "apply":
        apply(sys.argv[2], sys.argv[3], sys.argv[4])
    elif len(sys.argv) == 3 and sys.argv[1] == "lint":
        errs = lint(sys.argv[2])
        for e in errs:
            print("theme lint: " + e)
        if errs:
            sys.exit(1)
        print("theme lint: OK (%s)" % sys.argv[2])
    else:
        sys.exit(__doc__)


if __name__ == "__main__":
    main()
