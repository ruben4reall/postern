# dmgbuild settings for Postern's disk image: Postern on the left, Applications on the right, the brand's paper
# background. Written without Finder, so building the image never opens a window.
# Usage: dmgbuild -s scripts/dmg/settings.py -D app=<path to Postern.app> Postern <output.dmg>
import os

# dmgbuild runs this file with exec(): no __file__, only the -D values in `defines`. Paths are relative to the
# repository root, where scripts/release.sh runs.
application = defines["app"]  # noqa: F821 (provided by dmgbuild)

format = "UDZO"
compression_level = 9
filesystem = "HFS+"
files = [application]
symlinks = {"Applications": "/Applications"}
icon = os.path.join(application, "Contents", "Resources", "Postern.icns")
background = defines.get("background", "scripts/dmg/background.tiff")  # noqa: F821
window_rect = ((200, 140), (660, 420))
default_view = "icon-view"
show_toolbar = False
show_status_bar = False
show_pathbar = False
show_sidebar = False
icon_size = 112
text_size = 13
icon_locations = {"Postern.app": (165, 196), "Applications": (495, 196)}
