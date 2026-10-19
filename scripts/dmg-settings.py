"""Finder layout for the drag-to-install disk image (dmgbuild 1.6.7)."""
import os

application = os.path.abspath(defines["app"])
format = "UDZO"
filesystem = "HFS+"
files = [application]
symlinks = {"Applications": "/Applications"}
icon = os.path.join(application, "Contents", "Resources", "AppIcon.icns")
background = defines["background"]
# Finder includes its 32-point title bar in these bounds.
window_rect = ((300, 200), (640, 432))
default_view = "icon-view"
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
include_icon_view_settings = True
include_list_view_settings = False
arrange_by = None
grid_spacing = 80
icon_size = 96
text_size = 14
label_pos = "bottom"
icon_locations = {os.path.basename(application): (160, 220), "Applications": (480, 220)}
