"""Finder layout for the BackupCron drag-to-install disk image."""

import os
import subprocess

application = os.path.abspath(defines["app"])
artwork = os.path.abspath(defines["background"])
app_name = os.path.basename(application)

format = "UDZO"
filesystem = "HFS+"
files = [application]
symlinks = {"Applications": "/Applications"}
icon = os.path.join(application, "Contents", "Resources", "AppIcon.icns")
background = artwork

default_view = "icon-view"
show_toolbar = False
show_sidebar = False
show_status_bar = False
show_pathbar = False
show_tab_view = False
window_rect = ((180, 180), (754, 522))
arrange_by = None
grid_spacing = 80
scroll_position = (0, 0)
icon_size = 96
text_size = 13
label_pos = "bottom"
icon_locations = {app_name: (157, 264), "Applications": (413, 264)}


def create_hook(mount_point, options):
    """Verify the copied bundle before the image is sealed."""
    staged_app = os.path.join(mount_point, app_name)
    # Finder metadata on the copied bundle can invalidate strict verification.
    # Only clean the staging copy of our own build, never the input application.
    subprocess.run(["/usr/bin/xattr", "-cr", staged_app], check=True)
    subprocess.run(
        ["/usr/bin/codesign", "--verify", "--deep", "--strict", staged_app], check=True
    )
