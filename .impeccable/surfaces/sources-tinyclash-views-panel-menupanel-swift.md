---
version: 1
slug: "sources-tinyclash-views-panel-menupanel-swift"
primary_target: "Sources/TinyClash/Views/Panel/MenuPanel.swift"
related_targets: ["Sources/TinyClash/Views/Panel/HomeTab.swift","Sources/TinyClash/Views/Panel/ProxiesTab.swift","Sources/TinyClash/Views/Panel/ProfilesTab.swift","Sources/TinyClash/Views/Panel/RulesTab.swift","Sources/TinyClash/Views/Panel/SettingsTab.swift"]
---

# Surface: TinyClash menu bar panel (the whole app)

Mode: Operate. Audience: the author, daily, on their own Mac. Jobs: toggle system proxy / TUN, switch mode and nodes, test latency, switch or update profiles, read currently loaded rules, adjust settings, and read live state. The user requested no main window ("直接把它完全变成一个菜单栏app 不需要主页面", "合理设计，保留核心功能"), then added "增加一个规则tab 显示当前的规则" and refined Rules by removing search and aligning each rule card in two clean rows. Constraints: native SwiftUI controls, follows system light/dark, Simplified Chinese, fixed 360×560 pt content. Connections, expanded rule-provider contents, provider details and logs remain in metacubexd or the core log file.

## Direction contract

THESIS: The panel answers whether traffic is proxied, how, and through which primary group/node, before anything else. All everyday operations stay in a menu-bar popover, not a desktop window.

OWN-WORLD: Stash-inspired native macOS restraint: cool-neutral canvas, raised rounded panels (14 pt), SF system text and rounded tabular numerals. Selection uses the system accent; enabled tiles use its contrast-adjusted form for white text. Semantic green/orange/red latency thresholds are 500/1000 ms; download is blue and upload teal.

STORY: Open the menu-bar icon, read proxy state and active profile, control system proxy/TUN and mode on 首页; open 代理 for group details, latency, node selection, 添加策略组, in-place group editing (context menu / detail header pencil, keeping name read-only and unmanaged YAML keys intact) and deleting groups (context menu / detail header / edit page), which validates and writes standard YAML directly to the selected file; use 配置 for subscriptions/YAML; use 规则 for the core's actual matching order, refresh, 添加规则, clicking rows for in-place editing (with header trash), and context-menu row deletion, with two-row cards keeping payload/type left-aligned and chevron/policy right-aligned, using the same direct-file pattern without any custom-item manager; edits to groups or rules defer core restart by switching the header status pill to a clickable orange 「需重启生效」 while keeping Proxies and Rules lists in sync with the edited YAML; use 设置 for system/core/data actions.

FIRST VIEWPORT: Header (app mark, active profile, explicit proxy state; live speeds off Home), five tabs (首页 代理 配置 规则 设置), then on 首页: two toggle tiles, mode segmented control, compact group→node route ribbon with latency, live traffic chart and four facts, three quick actions, and a fixed bottom footer with 配置文档 / 退出 TinyClash. The footer stays outside the scroll view with a 12 pt bottom inset instead of leaving unused space below Home's content. Compact routes omit a duplicate mode chip because the segmented picker already shows it. Proxy cards echo the semantic latency palette in member health strips.

FORM: Pinned by "优化一下UI，现代一点 参考stash", the explicit menu-only scope, and the added runtime-rules tab. The user chose dashboard, node cards/latency, overall finish and menu-bar experience; no further aesthetic interview is needed.

FINISH: Build both configurations, verify rendered light/dark states and navigation, perform finish review, and keep DESIGN.md plus .impeccable/design.json current. Synthetic review data must be labelled; local screenshots are ignored by git and are not shipping raster assets.
