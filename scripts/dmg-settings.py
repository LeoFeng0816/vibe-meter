# dmgbuild 設定（由 scripts/build-dmg.sh 以 -D app=... -D background=... -D icon=... 呼叫）。
# 版面與 scripts/make-dmg-background.swift 的箭頭位置一致。
import os.path

application = defines["app"]  # noqa: F821  (dmgbuild 提供 defines)
appname = os.path.basename(application)

format = "UDZO"
filesystem = "HFS+"
size = None

files = [application]
symlinks = {"Applications": "/Applications"}
icon = defines.get("icon")  # noqa: F821  卷宗圖示（使用 App 的 AppIcon.icns）

background = defines["background"]  # noqa: F821
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
default_view = "icon-view"
show_icon_preview = False
window_rect = ((200, 120), (660, 420))
arrange_by = None
icon_size = 112
text_size = 13
label_pos = "bottom"
icon_locations = {
    appname: (165, 205),
    "Applications": (495, 205),
}
hide_extension = [appname]
