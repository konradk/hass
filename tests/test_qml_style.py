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

print("sensor rows and bar popups share one history renderer")
sensor_controls = open(os.path.join(ROOT, "controls", "SensorControls.qml"),
                       encoding="utf-8").read()
bar_graph = open(os.path.join(ROOT, "HistoryGraph.qml"), encoding="utf-8").read()
shared_plot = open(os.path.join(ROOT, "HistoryPlot.qml"), encoding="utf-8").read()
check("HistoryPlot {" in sensor_controls and "Canvas {" not in sensor_controls,
      "expanded sensor controls bypass HistoryPlot")
check("HistoryPlot {" in bar_graph and "Canvas {" not in bar_graph,
      "bar history graphs bypass HistoryPlot")
check("Canvas {" in shared_plot,
      "HistoryPlot has no shared renderer")

print("bar actions reserve geometry and follow layout revisions")
entity_row = open(os.path.join(ROOT, "EntityRow.qml"), encoding="utf-8").read()
room_card = open(os.path.join(ROOT, "RoomReadingsCard.qml"), encoding="utf-8").read()
check("barConfigSerial" in entity_row and "barConfigRevision" in entity_row,
      "entity bar state does not track the live layout revision")
check("barConfigSerial" in room_card and "barConfigRevision" in room_card,
      "room bar state does not track the live layout revision")
check("id: roomBarSlot" in room_card and "panelActionsVisible" in room_card,
      "room bar action has no permanent geometry slot")
check(entity_row.index("id: glyph")
      < entity_row.index("id: labels")
      < entity_row.index("id: entityPrimarySlot")
      < entity_row.index("id: entityBarSlot")
      < entity_row.index("id: entityExpandSlot"),
      "entity controls are not pin, name, primary, bar, chevron")
check(room_card.index("id: glyph")
      < room_card.index("id: headerLabels")
      < room_card.index("id: roomPrimarySlot")
      < room_card.index("id: roomBarSlot")
      < room_card.index("id: roomExpandSlot"),
      "room controls are not pin, name, primary, bar, chevron")
check("id: glyph" in entity_row
      and "onClicked: row.hass.toggleEntityPinned" in entity_row
      and "Style.selectedFillFor(row.fg, Color.accent)" in entity_row,
      "entity icon is not the selected pin button")
check("id: glyph" in room_card
      and "onClicked: card.pinRequested()" in room_card
      and "Style.selectedFillFor(card.fg, Color.accent)" in room_card,
      "room icon is not the selected pin button")
check("readonly property bool panelActionsVisible" in entity_row
      and "visible: row.barDataEligible && row.panelActionsVisible" in entity_row
      and "rowHover.hovered" in entity_row
      and "barActionHovered" not in entity_row,
      "entity bar action is not absent outside full-row hover")
check("readonly property bool panelActionsVisible" in room_card
      and "&& card.panelActionsVisible" in room_card
      and "card.rowHovered" in room_card
      and "rowHovered: rowHover.hovered" in entity_row
      and "cardHover" not in room_card
      and "barActionHovered" not in room_card,
      "room bar action is not absent outside full-card hover")
check("&& rowHover.hovered" in entity_row
      and "&& row.hass.showPanelPinOnHover" in entity_row
      and 'text: row.icon' in entity_row
      and "opacity: row.pinPreview ? 0.0 : 1.0" in entity_row
      and "visible: row.showIcon && row.pinPreview" in entity_row,
      "entity icon does not temporarily morph into a pin on full-row hover")
entity_glyph = next(block for _, block in blocks(entity_row, "Text")
                    if "id: glyph" in block)
check("width: row.showIcon ? implicitWidth : 0" in entity_glyph
      and "horizontalAlignment:" not in entity_glyph,
      "ordinary entity pinning still reserves a fixed icon slot")
check("readonly property bool pinPreview: card.showPanelPinOnHover" in room_card
      and "&& card.showIcon && card.rowHovered" in room_card
      and "rowHovered: rowHover.hovered" in entity_row
      and 'text: card.cardData.icon' in room_card
      and "opacity: card.pinPreview ? 0.0 : 1.0" in room_card,
      "room icon does not temporarily morph into a pin on full-card hover")
check("anchors.left: entityPrimarySlot.right" in entity_row
      and "anchors.right: entityExpandSlot.left" in entity_row
      and "id: entityExpandSlot\n          anchors.right: parent.right" in entity_row,
      "entity bar action is not centered between primary and chevron slots")
check("anchors.left: roomPrimarySlot.right" in room_card
      and "anchors.right: roomExpandSlot.left" in room_card
      and "id: roomExpandSlot\n        anchors.right: parent.right" in room_card,
      "room bar action is not centered between primary and chevron slots")
check(entity_row.count("TextMetrics {") >= 2
      and "readonly property real chevronInkLeft" in entity_row
      and "readonly property real barInkTarget" in entity_row
      and "entityBarMetrics.tightBoundingRect" in entity_row,
      "entity action centering does not measure rendered glyph ink")
check(room_card.count("TextMetrics {") >= 2
      and "readonly property real chevronInkLeft" in room_card
      and "readonly property real barInkTarget" in room_card
      and "roomBarMetrics.tightBoundingRect" in room_card,
      "room action centering does not measure rendered glyph ink")
check("foreground: row.barInBar ? Color.accent : row.fg" in entity_row,
      "entity remove action does not use the theme accent")
check("foreground: roomBarSlot.added ? Color.accent : card.fg" in room_card
      and "foreground: metric.added ? Color.accent : metric.qualityColor" in room_card,
      "room remove actions do not use the theme accent")
check("Row {\n        id: controlSlot" not in entity_row
      and "Row {\n      id: headerActions" not in room_card,
      "action slots still depend on a positioner")

panel = open(os.path.join(ROOT, "Panel.qml"), encoding="utf-8").read()
check("hass.isEntityPinned(entityId)" in panel
      and "expanded, pinned" in panel,
      "ordinary entity pins do not extend the room expansion default")
check("enabled: row.expandable && !row.pinned" not in entity_row
      and 'tooltipText: row.pinned ? "Pinned open"' not in entity_row,
      "an ordinary entity pin still disables manual collapse")

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
      and "item.expanded, item.pinned" in expand_cursor
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
room_pin_mouse = next(block for _, block in blocks(room_card, "MouseArea")
                      if "id: glyphPinMouse" in block)
check("enabled: card.showPanelPinOnHover && card.showIcon" in room_pin_mouse,
      "a disabled room pin shortcut still leaves an interactive panel target")
entity_pin_mouse = next(block for _, block in blocks(entity_row, "MouseArea")
                        if "id: glyphPinMouse" in block)
check("&& row.hass.showPanelPinOnHover" in entity_pin_mouse,
      "a disabled entity pin shortcut still leaves an interactive panel target")
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
check("pinned: modelData.pinned" in settings,
      "the Devices list does not project saved room pin state")
check(settings.count("pinnable: modelData.pinnable === true") == 2,
      "the Devices lists do not project pinnability for every row kind")

print()
if failures:
    for failure in failures:
        print("  FAIL %s" % failure)
    print("\nFAILED: %d of %d checks" % (len(failures), checks))
    sys.exit(1)
print("all %d checks passed across %d files" % (checks, len(QML_FILES)))
