# dmgbuild settings of the Bandito install disk image: the window, the background, the icon positions, the volume icon.
# Used by make-dmg.sh, which passes these defines:
#   app         the Bandito.app to put on the image
#   icon        its AppIcon.icns, used as the volume icon
#   background  brand/dmg/background.tiff (660x420 and @2x in one file)
# dmgbuild writes the layout straight into .DS_Store: no Finder, no AppleScript, so it runs in CI.
# Positions are icon centres in points. The window is 660x420; the background's slots are 128 pt squares centred on them.
import os

app = defines["app"]  # noqa: F821 - defines is provided by dmgbuild
app_name = os.path.basename(app.rstrip("/"))

# make-dmg.sh builds a writable image (UDRW), fixes the Finder labels in dmg_labels.py, then converts it to UDZO.
format = defines.get("format", "UDZO")  # noqa: F821
files = [app]
symlinks = {"Applications": "/Applications"}
icon = defines["icon"]  # noqa: F821
background = defines["background"]  # noqa: F821

show_status_bar = False
show_pathbar = False
show_tab_view = False
show_toolbar = False
show_sidebar = False
show_icon_preview = False
default_view = "icon-view"
include_icon_view_settings = "auto"
include_list_view_settings = False
arrange_by = None
grid_offset = (0, 0)
grid_spacing = 100
scroll_position = (0, 0)
label_pos = "bottom"
text_size = 13
icon_size = 128
# dmgbuild writes the outer window size (Finder reports 660x448 for this value), title bar included. UNVERIFIED: the
# content height is not yet confirmed on screen (the bottom line was hidden by the path and status bars in tests).
TITLE_BAR_PT = 28
window_rect = ((100, 100), (660, 420 + TITLE_BAR_PT))
icon_locations = {
    app_name: (170, 214),
    "Applications": (490, 214),
}
