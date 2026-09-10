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
panel = open(os.path.join(ROOT, "Panel.qml"), encoding="utf-8").read()
entity_row = open(os.path.join(ROOT, "EntityRow.qml"), encoding="utf-8").read()
room_card = open(os.path.join(ROOT, "RoomReadingsCard.qml"), encoding="utf-8").read()
settings_row = open(os.path.join(ROOT, "SettingsEntityRow.qml"), encoding="utf-8").read()
settings = open(os.path.join(ROOT, "Settings.qml"), encoding="utf-8").read()
service = open(os.path.join(ROOT, "Service.qml"), encoding="utf-8").read()
check("property var collapsedPinnedRows: []" in panel
      and "function pinnedExpansionVisible(" in panel
      and "function toggleRowExpansion(" in panel
      and "collapsedPinnedRows = []" in panel,
      "room pins do not act as resettable per-open expansion defaults")
expand_cursor = panel[panel.index("function expandCursor()"):
                      panel.index("// Colour carries the state")]
check("toggleRowExpansion(" in expand_cursor
      and "expandedEntityId =" not in expand_cursor,
      "keyboard expansion bypasses the shared pinned-row transition")

room_glyph = next(block for _, block in blocks(room_card, "Text")
                  if "id: glyph" in block)
check("visible: card.showIcon" in room_glyph
      and "width: card.showIcon ? implicitWidth : 0" in room_glyph
      and "horizontalAlignment:" not in room_glyph,
      "room icon does not follow the ordinary entity icon visibility geometry")
check("property bool showIcon: true" in room_card
      and "showIcon: row.showIcon" in entity_row
      and "anchors.leftMargin: card.showIcon ? Style.spacing.xl : 0" in room_card,
      "grouped reading rows do not respect showEntityIcons")
check("readonly property bool pinPreview: card.showPanelPinOnHover" in room_card
      and "&& card.showIcon && card.rowHovered" in room_card
      and "rowHovered: rowHover.hovered" in entity_row,
      "the room pin preview does not inherit the complete parent-row hover area")
check('text: card.cardData.icon' in room_glyph
      and "opacity: card.pinPreview ? 0.0 : 1.0" in room_glyph
      and "anchors.centerIn: glyph" in room_card
      and 'text: ""' in room_card,
      "the hover pin replaces the device icon without preserving its layout width")
check("onClicked: card.pinRequested()" in room_card
      and "onPinRequested: row.hass.toggleRoomReadingPinned" in entity_row,
      "the panel room pin is not interactive")
pin_mouse = next(block for _, block in blocks(room_card, "MouseArea")
                 if "id: glyphPinMouse" in block)
check("enabled: card.showPanelPinOnHover && card.showIcon" in pin_mouse,
      "a disabled room pin shortcut still leaves an interactive panel target")
check("property bool showPanelPinOnHover: false" in service
      and "function setShowPanelPinOnHover(enabled)" in service
      and 'label: "Show pin shortcut on hover"' in settings
      and "checked: root.service ? root.service.showPanelPinOnHover : false" in settings,
      "the panel pin hover shortcut is not exposed as an opt-in General setting")

check('id: pinAction' in settings_row
      and 'visible: row.pinnable && row.reorderable' in settings_row
      and 'row.service.toggleRoomReadingPinned(row.entityId)' in settings_row,
      "the selected Devices row has no room pin action")
pin_index = settings_row.find("id: pinAction")
move_up_index = settings_row.find('tooltipText: "Move up"')
move_down_index = settings_row.find('tooltipText: "Move down"')
star_index = settings_row.find("md-star / md-star_outline")
check(pin_index >= 0 and move_up_index >= 0 and move_down_index >= 0
      and star_index >= 0
      and pin_index < move_up_index < move_down_index < star_index,
      "the pin is not immediately before the reorder actions")
pin_block = next(block for _, block in blocks(settings_row, "PanelActionButton")
                 if "id: pinAction" in block)
check("bordered:" not in pin_block
      and "row.pinned ? Color.accent : Color.muted" in pin_block,
      "the settings pin uses geometry instead of colour to show saved state")
# The device lists are reconciled into ListModels, so a row's saved pin state
# and pinnable flag reach the delegate as model roles rather than a modelData
# object. Both must still be projected from the room-reading source rows.
check("pinned: r.pinned === true" in settings,
      "the Devices list does not project saved room pin state")
check("pinnable: r.roomReading === true" in settings,
      "the Devices list does not identify pinnable room rows")
check("pinned: browseRow.pinned" in settings and "pinned: favRow.pinned" in settings,
      "a device row delegate does not forward saved pin state to the entity row")

print()
if failures:
    for failure in failures:
        print("  FAIL %s" % failure)
    print("\nFAILED: %d of %d checks" % (len(failures), checks))
    sys.exit(1)
print("all %d checks passed across %d files" % (checks, len(QML_FILES)))
