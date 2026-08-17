#!/usr/bin/env python3
"""Guards the house style of the QML. Run: python3 tests/test_qml_style.py

These are the mistakes that do not throw, do not warn, and do not show up in
any log — they only show up when you put a screenshot of this plugin next to a
screenshot of a built-in one. The whole UI shipped without a single
`font.family` and rendered in a different typeface from the rest of the shell
for four phases before anyone noticed.
"""

import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

# Components that carry their own font, so a bare `Text` inside them is not
# the thing being checked here.
QML_FILES = []
for dirpath, dirnames, filenames in os.walk(ROOT):
    dirnames[:] = [d for d in dirnames if d not in (".git", "tests", "docs")]
    for name in sorted(filenames):
        if name.endswith(".qml"):
            QML_FILES.append(os.path.join(dirpath, name))

failures = []
checks = 0


def rel(path):
    return os.path.relpath(path, ROOT)


def blocks(source, opener):
    """Yield (line_number, block_text) for each `opener` block, brace-matched."""
    for match in re.finditer(r"(?m)^[ \t]*" + re.escape(opener) + r"\s*\{", source):
        start = match.end() - 1
        depth = 0
        for index in range(start, len(source)):
            if source[index] == "{":
                depth += 1
            elif source[index] == "}":
                depth -= 1
                if depth == 0:
                    yield source.count("\n", 0, match.start()) + 1, source[start:index]
                    break


def check(condition, message):
    global checks
    checks += 1
    if not condition:
        failures.append(message)


print("every Text sets a font family")
for path in QML_FILES:
    source = open(path, encoding="utf-8").read()
    for line, block in blocks(source, "Text"):
        check("font.family" in block,
              "%s:%d Text without font.family" % (rel(path), line))

print("every Text pins textFormat to plain")
for path in QML_FILES:
    source = open(path, encoding="utf-8").read()
    for line, block in blocks(source, "Text"):
        # Qt's default is AutoText, which sniffs for markup and renders it as
        # rich text. Entity names come from Home Assistant and overrides come
        # from config.json, so a device called `<img src="http://…">` would
        # fetch it on render. Nothing here ever wants markup.
        check("textFormat: Text.PlainText" in block,
              "%s:%d Text without textFormat: Text.PlainText" % (rel(path), line))

print("no hardcoded palette entries where the bar's colours belong")
for path in QML_FILES:
    source = open(path, encoding="utf-8").read()
    # Color.muted is not part of the panel vocabulary: the built-ins dim the
    # bar's own foreground instead, so a theme that recolours the bar carries
    # the secondary text with it.
    if os.path.basename(path) in ("Settings.qml", "SettingsEntityRow.qml"):
        continue   # the settings overlay sits on the menu surface, not the bar
    for number, text in enumerate(source.splitlines(), start=1):
        check("Color.muted" not in text,
              "%s:%d uses Color.muted; dim the bar foreground instead"
              % (rel(path), number))

print("a padded BorderSurface actually applies its insets")
for path in QML_FILES:
    source = open(path, encoding="utf-8").read()
    for line, block in blocks(source, "BorderSurface"):
        if not re.search(r"\bpadding\s*:", block):
            continue
        # `padding` on a BorderSurface only computes contentLeftInset and
        # friends — it does not move children. Forgetting to apply them is
        # invisible in code review and shows up as text glued to the border.
        check(re.search(r"content(Top|Left|Right|Bottom)Inset", source) is not None,
              "%s:%d BorderSurface sets padding but nothing reads content*Inset"
              % (rel(path), line))

print("only a device-declared step quantizes a drag")
for path in QML_FILES:
    source = open(path, encoding="utf-8").read()
    for line, block in blocks(source, "SliderRow"):
        # `control.step` is the climate entity's own target_temp_step; every
        # other slider steps by a UI nudge size.
        device_step = re.search(r"step:\s*control\.step\b", block) is not None
        check(("snap: true" in block) == device_step,
              "%s:%d SliderRow snaps to a step the device never declared"
              % (rel(path), line))

print("PanelActionButton instances pass a font family")
for path in QML_FILES:
    source = open(path, encoding="utf-8").read()
    for line, block in blocks(source, "PanelActionButton"):
        check("fontFamily" in block,
              "%s:%d PanelActionButton without fontFamily" % (rel(path), line))

print()
if failures:
    for failure in failures:
        print("  FAIL %s" % failure)
    print("\nFAILED: %d of %d checks" % (len(failures), checks))
    sys.exit(1)
print("all %d checks passed across %d files" % (checks, len(QML_FILES)))
