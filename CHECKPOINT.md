# Toolbox InputRouter source checkpoint

The unmodified pre-repair source is preserved at commit `38805c7096d1f7b3841ee9a41cb02fcbeee9879e` on `checkpoint/toolbox-inputrouter-20261019`. This branch adds the independent Windows physical USB keyboard / RDP session repair. The installed Mac App remains 1.10.1 (46), with its existing input, gesture, speech and clipboard source unchanged.

The existing Toolbox Shared dependency is preserved in `ToolboxShared/`. Copy it beside the restored InputRouter directory as `Shared/` when building in isolation. Local host trust, authentication files, build output and runtime evidence remain on the original machine and are excluded from Git.
