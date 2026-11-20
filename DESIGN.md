---
name: TinyClash
description: Stash-inspired, restrained native macOS menu-bar controls for mihomo.
colors:
  canvas-light: "rgb(96.1% 96.1% 95.7%)"
  canvas-dark: "rgb(8.6% 9.0% 10.2%)"
  panel-light: "rgb(100% 100% 100%)"
  panel-dark: "rgb(12.9% 13.3% 14.9%)"
  inset-light: "rgb(0% 0% 0% / 4.5%)"
  inset-dark: "rgb(100% 100% 100% / 7.5%)"
  chart-label-light: "rgb(38.8% 40.8% 44.7%)"
  chart-label-dark: "rgb(62.0% 63.9% 67.8%)"
typography:
  title:
    fontFamily: "macOS system (.default)"
    fontWeight: 600
  body:
    fontFamily: "macOS system (.default)"
    fontWeight: 400
  label:
    fontFamily: "macOS system (.default)"
    fontWeight: 500
  speed:
    fontFamily: "macOS system (.rounded)"
    fontSize: "20pt"
    fontWeight: 600
  metric:
    fontFamily: "macOS system (.rounded)"
    fontSize: "12pt"
    fontWeight: 500
  latency:
    fontFamily: "macOS system (.rounded)"
    fontSize: "11pt"
    fontWeight: 500
rounded:
  panel: "14pt"
  tile: "10pt"
  chip: "6pt"
  section: "12pt"
spacing:
  xs: "4pt"
  s: "8pt"
  m: "12pt"
  l: "16pt"
  xl: "24pt"
components:
  toggle-tile:
    rounded: "{rounded.tile}"
    padding: "10pt 12pt"
  action-tile:
    rounded: "{rounded.tile}"
    padding: "9pt 0pt"
  tab:
    rounded: "{rounded.tile}"
    padding: "6pt 0pt"
  panel:
    rounded: "{rounded.panel}"
    padding: "{spacing.l}"
  compact-panel:
    rounded: "{rounded.panel}"
    padding: "{spacing.m}"
  panel-section:
    rounded: "{rounded.section}"
  tag:
    rounded: "{rounded.chip}"
    padding: "2pt 6pt"
  route-segment:
    rounded: "{rounded.chip}"
    padding: "4pt 8pt"
  route-segment-compact:
    rounded: "{rounded.chip}"
    padding: "3pt 6pt"
  node-cell:
    rounded: "{rounded.tile}"
    padding: "8pt 10pt"
  rule-row:
    padding: "7pt 12pt 7pt 6pt"
---

# Design System: TinyClash

## Overview

**Creative North Star: "Stash-inspired native macOS restraint"**

TinyClash uses the confirmed Stash for Mac reference through native macOS controls, a softly tinted canvas, raised rounded panels, and the icon's OrangePulse accent that identifies selection and enabled proxy controls. This is an operational interface: readable state and familiar behavior take precedence over decoration. Its shipping surface is a native SwiftUI menu-bar panel, not a web application or a reduced desktop window.

The system follows macOS light and dark appearance. Standard system text and SF Symbols carry the interface; rounded, monospaced digits distinguish live network values. Simplified Chinese labels stay compact, with secondary text used for profile names, node details, and supporting information.

This document records the implementation in `Sources/TinyClash/Views/Theme.swift`, `Components.swift`, `Panel/MenuPanel.swift`, `Panel/HomeTab.swift`, and `Panel/ProxiesTab.swift`. Values are source-extracted, not a claim of rendered validation. `PRODUCT.md` and the existing menu-panel surface brief supply the confirmed direction, not additional tokens. The frontmatter uses native points and records literal source colors as CSS sRGB percentages without rounding. Native semantic colors and semantic font sizes remain system-resolved; no fixed substitutes are prescribed. The sidecar's HTML/CSS specimens are representative rendered equivalents only, not shipping source.

**Key Characteristics:**
- Adaptive cool-neutral canvas and raised panels.
- OrangePulse brand orange for selection and enabled controls; semantic color for network state.
- Native system typography, SF Symbols, and rounded tabular numerals.
- Compact spacing, continuous rounded corners, and restrained interaction feedback.

## Colors

The neutral palette separates canvas, panel, and inset fill; OrangePulse orange identifies actions and selection, while adaptive system colors retain their network-state and traffic-series roles.

### Primary

- **OrangePulse brand ramp** (derived from `03 OrangePulse.svg`: `#FF9661` → `#F27234`, hue ~20°): unified across the entire panel so settings controls, tabs, mode selection, toolbar primaries, and profile/node selections speak one brand voice. `Theme.accent` adapts to `#F57B3F` in dark appearance and clean, fresh `#EB6728` in light appearance for graphical controls (switches, borders, checkmarks, usage bars, native pickers); `Theme.accentHighlight` (`#FF9661`) and `Theme.brandPulseBottom` (`#F27234`) reproduce the AppIcon pulse dot in `TinyClashBadge`. Small text and icon+label actions (active tab, selected mode segment, list-toolbar primaries, subpage 返回/保存/添加, settings inline actions, selected node names, outbound proxy nodes) use `Theme.accentForeground`: luminous `#FF8E53` in dark appearance and warm terracotta-orange `#BA440F` in light appearance, clearing ≥4.5:1 contrast across canvas, panel, selected surfaces, warm control fills, and tags (12% dark / 10% light). Toolbar hover lifts to `#FFA778` in dark and deepens to `#9B3609` in light. The active tab, selected mode segment, appearance picker thumb, and terminal route segment all share `Theme.selectedSurface`: crisp white in light appearance (over warm studio stone `#F5F5F4` canvas) and machined graphite `#2F3137` in dark appearance. Enabled toggle tiles adapt their visual weight to the appearance so they stay clear without overwhelming a bright canvas: in dark appearance they use a solid deep-orange gradient (`Theme.activeTileGradient`, `#D45218` → `#BC4210`, white text ≥4.7:1 at midpoint / ≥5.3:1 on subtitle), a subtle 0.5 pt top specular highlight stroke, white content, and a 20% white icon circle; in light appearance they use soft warm ivory-apricot `Theme.controlFill` (`#FFF5EF`) with a 1 pt 28% `Theme.accent` border, a solid OrangePulse icon badge (`Theme.activeBadgeGradient`, `#F06E2D` → `#DC5518`) with a white glyph, primary title, `Theme.accentForeground` (`#BA440F`) status text, and a subtle neutral lift. Selected node cards and settings inline action buttons share opaque `Theme.controlFill` (`#FFF5EF` light / `#2D231E` dark), paired with a fine accent border and `Theme.accentForeground` text.

### Secondary

- **Download blue** (`Theme.download`, `#4DA3FF` dark / `#1A68C4` light): download labels, download chart series, TCP tags, domain rule types, and 自动 group tags.
- **Upload seafoam teal** (`Theme.upload`, `#32D2C4` dark / `#0B7574` light): upload labels, upload chart series (deliberately separated in hue from download blue for line readability), UDP tags, 故障转移 groups, and 远程 rule-set tags.

### Tertiary

- **Active emerald** (`Theme.active`, `#45D483` dark / `#197B40` light): traffic takeover status, DIRECT, and successful latency readings below 500 ms; harmonized with `StatusBadge` (`#9BE8B8` on `#183B27` dark; `#196B3A` on `#E6F5EC` light).
- **Warning amber** (`Theme.warning` / `Theme.warningText`, `#F5B43B` dark / `#9F5C00` light): shifted to golden amber so warnings, starting/restarting states, expiry notices, and 500–999 ms latency never collide with OrangePulse brand orange. Always paired with an icon or explicit label.
- **Failure crimson** (`Theme.failure`, `#FF6467` dark / `#C92A35` light): core failure, timeout, error notices, REJECT, and latency of 1000 ms or more.
- **Latency dots & health strip** (`Theme.latencyDot`): in light appearance, 6×6 pt graphical dots use fresher jewel tones (`#27AE60` green, `#E8980C` amber, `#E03E47` red) so small dots stay vivid rather than muddy while accompanying numerals retain ≥4.5:1 WCAG AA text contrast.
- **Tag-only hues**: indigo (`#8E90FF` / `#524CC2`), purple (`#C484FA` / `#7E46B8`), and rose pink (`#F8729D` / `#B83265`) for IP / RULE-SET / MATCH rule types, 负载均衡 groups, and 本地 / 内联 rule sets. Every semantic and tag color clears ≥4.5:1 contrast on both `Theme.panel` and its tinted tag fill in both appearances.

### Neutral

- **Cool canvas** (`Theme.canvas`, `canvas-light` / `canvas-dark`): opaque whole-panel background, resolved by AppKit appearance. It covers the native menu-bar material and ignores safe areas; desktop colors never show through. No custom visual-effect background remains in the preview window.
- **Raised surface** (`Theme.panel`, `panel-light` / `panel-dark`): opaque cards, action tiles, and grouped settings surfaces.
- **Inset fill** (`inset-light` / `inset-dark`): inactive controls, nonterminal route segments, and selectable unselected-row hover.
- **Native text hierarchy** (`.primary`, `.secondary`, `.tertiary`, `.quaternary`): content, supporting labels, chevrons/placeholders, and unselected node circles. Preserve native semantic styles for those roles.
- **Chart labels** (`chart-label-light` / `chart-label-dark`): explicit opaque adaptive gray at 10 pt, avoiding compounded secondary-style attenuation in Swift Charts.

### Named Rules

**The Semantic Latency Rule.** Preserve the implemented thresholds: nil is untested, zero is timeout, positive values below 500 ms are green, 500–999 ms are orange, and 1000 ms or more are red. Pair color with a readable value, “超时”, or an explicit placeholder; the decorative health strip is not the sole reading.

## Typography

**Body and title font:** macOS system default design, through SwiftUI semantic styles. On macOS this is the system San Francisco interface family; the source does not bundle or select a custom font.

**Numeric font:** macOS system rounded design with `.monospacedDigit()`, via `Theme.numeral`. This is tabular numerals, not a switch to a monospaced text family.

### Hierarchy

- **Title:** `.headline` for app and subpage titles; `.callout.weight(.semibold)` for toggle labels, group names, and selected node names.
- **Body:** `.callout` for rows, node names, and route content; unselected node names remain regular weight.
- **Supporting text:** `.caption` for profile names, secondary group content, and status; `.caption2` for tags, tab labels, node details, action labels, and metric labels. Medium and semibold weights are applied only where shown by the component.
- **Speed:** the Home traffic card uses rounded semibold numerals (`speed`). The component's generic default is 26 pt, but Home explicitly passes 20 pt; the generic default is not a panel-wide display size.
- **Metric:** rounded medium numerals (`metric`) for connection, memory, total, and port values.
- **Latency:** rounded medium numerals (`latency`) by default and in compact routes; noncompact routes request 12 pt. Non-Home header speeds also use 11 pt rounded medium numerals.

Semantic text styles retain platform-controlled sizes and line metrics. The source establishes neither a fixed type-scale ratio nor custom line heights or tracking.

### Named Rules

**The Stable Numerals Rule.** Use `Theme.numeral` for live speed, traffic, and latency readouts so rounded forms and monospaced digits remain consistent; keep surrounding labels in the default system design.

## Layout

- The menu panel has a fixed native frame (360 × 560 pt). There are no responsive breakpoints in the inspected implementation. Content scrolls inside this frame rather than resizing into a window layout.
- Header, navigation, and scrolling content use a 14 pt horizontal inset. Home and proxy-list content have 14 pt outer padding. Header padding is 12 pt above and 10 pt below; the tab bar has 10 pt below it.
- The named spacing scale comes from `Theme.Space`. Most Home vertical grouping uses `m`; paired toggles and action tiles use `s`; proxy cards are stacked at `s`; node rows are stacked at `xs`.
- `PanelBackground` defaults to `l` internal padding. Traffic and proxy group cards explicitly use `m`. `PanelSection` groups zero-spacing settings rows; each `PanelRow` has 12 pt horizontal padding and a minimum height of 36 pt.
- Home's toggle pair and three action tiles share available width equally. Traffic facts use four equal-width columns. The upload speed block has an explicit 130 pt width.
- Long profile/group labels use a single line. Node and selected-route names use truncation; route segments truncate in the middle, and the terminal segment receives layout priority.
- Header speeds appear only off Home while the core is running. Home has its own larger speed readouts. Do not duplicate the header-speed treatment onto Home based solely on the earlier surface brief.

## Elevation & Depth

Depth uses opaque tonal layering and a half-point `Theme.panelBorder` outline. `PanelBackground`, action tiles, rule cards, and grouped settings surfaces share this restrained border treatment rather than glass or decorative shadows. This does not ban native dividers, native field borders, or row separators, all of which exist in the inspected code.

### Shadow Vocabulary

- **Panel and compact surface:** no added shadow; a 0.5 pt outline uses white at 9% opacity in dark appearance and black at 7% in light appearance.

The sidecar preserves these native expressions. Its browser specimens use representative CSS shadows, not an assertion that SwiftUI blur radius and CSS blur are identical.

### Named Rules

**The Raised Panel Rule.** Reuse opaque tonal surfaces and the shared half-point outline for cards; do not reintroduce translucent materials or stack decorative shadows on top. Retain native dividers and field borders where the component already uses them.

## Shapes

- **Panel:** large continuous rounded corners (`rounded.panel`) for traffic and group cards.
- **Tile:** tighter continuous rounded corners (`rounded.tile`) for proxy toggles, action tiles, tabs, node rows, rule cards, and inline error notices.
- **Section:** grouped settings containers derive their radius from tile plus 2 pt (`rounded.section`).
- **Chip:** every text-on-fill element — route chips, tags, status badges, and footer controls — uses the same small continuous rounded corners (`rounded.chip`), never a capsule or a one-off radius. Tags use 12% tinted fill; status badges use a 7 pt dot and 8 pt horizontal / 3 pt vertical padding. Latency dots and health-strip marks are 6 × 6 pt; health strips have 3 pt gaps, show at most 28 marks, and append a text overflow count.

## Components

### Toggle tiles and action tiles

`ToggleTile` is a large labeled action, not a native switch. Its enabled state uses the soft adaptive apricot control fill and contrasting warm content; off uses inset fill and primary/secondary text. A 32 pt icon circle holds a symbol or small progress indicator. While working it rejects repeated actions; externally unavailable tiles have 50% opacity. Its accessibility label and on/off value are explicit.

Home action tiles use raised panel fill, a symbol over a caption-sized label, and the compact shadow. Disabled action tiles use 45% opacity. Both tile families use `PressableStyle`: 0.98 pressed scale and 85% pressed opacity, with ease-out over 0.12 s. With Reduce Motion, that style suppresses animation and scaling but retains opacity feedback.

`hoverHighlight` overlays primary text color at 4.5% opacity, with ease-out over 0.12 s unless Reduce Motion is enabled. It is applied to action tiles, proxy cards, and rule cards, not universally to every control. Toggle on/off fill changes separately animate over 0.18 s, with that animation disabled when Reduce Motion is enabled.

### Native controls and fields

Home uses a native segmented picker for mode selection. Group search uses `TextField` with `.roundedBorder`, shown only when a group has more than ten members. Test actions use native borderless buttons, latency actions use plain buttons, and the empty-state import action uses `.borderedProminent`. Preserve those platform treatments; the inspected code provides no custom focus ring or custom text-field error style.

Settings draws its own switches (`SettingsSwitchStyle`) and inline action buttons (`SettingsActionStyle`) instead of using native ones: the menu bar app is usually inactive, so native controls render with grey knobs, a dimmed tint, and grey buttons. Switches use the unified `Theme.accent` track (`#F57B3F` dark / `#E05A1F` light) with a white knob (also reused in rule/group editor toggles). Inline action buttons use `Theme.accentForeground` medium text on opaque `Theme.controlFill` with a 0.5 pt 28% `Theme.accent` hairline border. The appearance picker shares the same elevated `Theme.selectedSurface` thumb (with hairline border and subtle shadow) and `Theme.accentForeground` icon as the tab bar and mode picker. The 协议栈 popup remains native and inherits the panel tint (`Theme.accent`), matching the pickers in 策略 and 规则. `panelPicker` rebuilds the popup when the color scheme changes, because a live native popup otherwise falls back to the system accent color.

The Profiles tab uses the same top toolbar as 策略 and 规则: profile count, 「节点列表」, and a prominent 「添加」 menu (添加订阅… / 导入 YAML 文件… / 新建空白配置). Each remote profile card's menu offers “更新订阅” (alongside the card's refresh button), and every profile card's menu additionally offers “更新订阅节点” for the selected, running configuration, including local YAML: it updates only HTTP `proxy-providers`, shows an in-card progress indicator, then refreshes the node list without rewriting YAML, restarting the core, or updating rule providers. For noncurrent or stopped profiles the disabled item's own title states the reason (「需先切换到此配置」 / 「需先启动内核」) instead of an extra inert menu row; enumeration errors, absent HTTP subscriptions, and individual update failures are reported rather than silently treated as success.

### Tags and status

`Tag` uses caption2 medium text, tinted foreground, a 12% tinted `rounded.chip` fill, and compact padding. Tags carry meaning through tint: rule types by match target, group types by strategy, and rule set sources as 远程 teal, 本地 indigo, 内联 pink; profile kind tags stay neutral. `StatusBadge` pairs text with its semantic dot: running and proxying is green “运行中”, with an opaque pale-mint background (`#DCEEE2`) and dark-green text/dot (`#145C2F`) in light appearance, and an opaque dark-green background (`#183D26`) with soft-mint text/dot (`#A7E5BA`) in dark appearance, keeping contrast stable in both appearances; reloading or restarting shows orange “重启中”; quitting shows secondary “关闭中” while the header power action dims and disables; running without takeover is secondary “未接管流量”; stopped is red “已停止”; starting is orange; failure is red. A running core alone does not imply active traffic takeover.

### Navigation

The five equal-width tabs (首页, 策略, 配置, 规则, 设置) pair SF Symbols with caption2 medium labels. The active tab uses `Theme.selectedSurface` (hairline border, 1 pt soft shadow) with `Theme.accentForeground` icon/label; inactive tabs use secondary text on clear fill with hover highlight. They use `PressableStyle`, expose selection to accessibility, and support Command–1 through Command–5. Subpage headers use a native borderless “返回” action with the cancel keyboard shortcut. The shared header's quit action is a secondary `power` icon button that turns failure red on hover (⌘Q, tooltip and accessibility label 「退出 TinyClash」). Home has no footer: quit lives in the shared header and the mihomo configuration-docs link lives in Settings → 内核与数据 → mihomo menu.

### Panels and proxy groups

`PanelBackground` supplies the reusable raised card. Group cards contain a semibold group name, a type tag (手动 neutral, 自动 blue, 故障转移 teal, 负载均衡 indigo), a secondary current-route label that resolves nested group selections to the final node (`节点选择 › 自动选择 › 节点`, head-truncated) with that node's latency, a latency reading, and a decorative health strip. Clicking a group opens its in-panel detail. The Proxies toolbar keeps “添加策略组” visible even while the core is stopped or in direct mode, provided a profile is selected. Additions, in-place edits (via card context menu or detail header edit icon for non-`GLOBAL` groups, keeping the name read-only and preserving unmanaged YAML keys), and deletions (via card context menu, the detail header ⋯ menu, or edit page trash action, each confirmed first) validate and write standard multi-line YAML to that profile's file and automatically reload the configuration when the core is running; no custom-group manager or badges are shown. Rules are added, edited, and deleted directly from Rules, not Settings. While testing, test actions keep their footprint: the label hides and a small progress indicator sits in its place, so neighbouring header buttons never shift; do not style it as a completed measurement. 「测速」 on the group list tests up to four groups concurrently. The group detail header carries only two actions: 测速 and a ⋯ menu holding 按延迟排序, 编辑策略组… and 删除策略组…. Node cards show a protocol subtitle only when the group mixes protocols (built-in DIRECT/REJECT excluded); otherwise the subtitle line stays empty so cells keep one height.

### Route ribbon

`RouteRibbon` shows the resolved group/node chain and the final node's latency when available. The noncompact variant also shows mode; the compact variant omits that redundant chip because the segmented picker already shows the selected mode. Secondary segments use inset fill; the last segment uses primary semibold text at the variant's size (callout, or caption when compact) on `Theme.selectedSurface` and retains layout priority 1. Small tertiary chevrons separate segments. Direct mode explicitly says all traffic is direct; empty chains use loading or empty-state copy instead of inventing a route.

### Node cards

Group members render as a two-column `LazyVGrid` of `node-cell` cards (`s` gaps), roughly doubling the nodes visible per screen. Each card is a real `Button` (keyboard reachable): the middle-truncated name sits on top, an optional protocol subtitle below, and the latency reading in the bottom-right corner is a separate test button that becomes a mini progress indicator during testing. Unselected cards use the raised panel fill and hairline border; the selected card uses `Theme.controlFill`, a 1 pt 45% accent border, semibold `Theme.accentForeground` name and a small checkmark. Hover feedback only applies to enabled (selectable) cards. Nonselectable automatic groups keep informational cards and explain why manual selection is unavailable. The context menu offers 测试延迟 and 复制节点名.

### Menu bar speed

`MenuBarSpeedImage` follows TinyNet's two-line template-image approach rather than a variable-width SwiftUI text label. Upload (`↑`) is above download (`↓`), using 8 pt bold system monospaced text, right-aligned within a fixed 66 × 22 pt speed column. The existing 18 pt active/idle status mark is centered vertically to its left with a 4 pt gap, producing one 88 × 22 pt template image. AppKit supplies display-scale rasterization and system menu-bar tinting. The input remains mihomo bytes/s, displayed from KB/s upward using binary conversion, two decimals and a minimum six-character numeric field; units extend through EB/s to keep extreme values within the fixed column. An image is reused while formatted text and proxy status remain unchanged. Disabling menu-bar speed or stopping the core restores the original status icon without a speed column; the Home chart formatter is unchanged.

### Traffic readouts and chart

The Home card pairs blue download and teal upload labels with numeric readouts. Speed text uses `.numericText()` transitions. Its native Swift Charts plot is at least 72 pt high and grows to absorb the panel's remaining height, so Home never leaves empty space below the quick actions (when the core is not running and the chart is absent, the quick actions sit at the bottom instead); the content still scrolls when an error banner pushes it past the panel, with monotone interpolation and 1.4 pt line strokes. Only download has an area fill, fading from 30% to 2% opacity. The horizontal axis and legend are hidden; the trailing vertical axis requests two speed labels with dashed half-point grid lines. History-count changes explicitly disable chart animation. These are observations of the existing chart, not additional chart tokens or new visualization design.

### Runtime rules

The Rules tab mirrors Proxies' card-list structure: its toolbar shows the rule count (with a tooltip noting matching order and unexpanded RuleSet references), a refresh action, and a visible “添加规则” action (with no custom-item management menu). Rule types display in their YAML spelling (`DOMAIN-SUFFIX`, `IP-CIDR`, `GEOIP` with upper-case country codes), not the core's runtime names, so the list matches the editor and the file. Rules render as compact rows inside one grouped container (`rounded.section`, hairline border, inset dividers) rather than separate cards, because rule lists run to hundreds of entries and order is what matters: each `rule-row` shows its 1-based matching-order ordinal in a fixed-width tertiary numeral column, the middle-truncated match content on the first line, and below it the rule type as tinted caption2 text on the left (domain/GEOSITE blue, IP/GEOIP indigo, RULE-SET purple, MATCH pink, others neutral; the payload-less MATCH rule shows “Default”) with the semantic destination policy (`DIRECT` green, `REJECT` red, other policies primary text) on the right, so varying type widths never stagger the match content; clicking a row opens an in-panel editor prefilled from the profile YAML (preserving order, inline comments, and extra options, with a header trash action), and a context menu offers edit, copy payload/policy, and direct deletion after `mihomo -t` validation. `LazyVStack` keeps longer configurations scrollable. Collection references remain references, not invented expanded lists. The page has explicit loading, stopped, empty, error/retry, and non-rule-mode states; rule creation and editing stay in-panel. Adding, saving, or deleting validates and persists directly to YAML and automatically reloads the configuration when the core is running. Forms explain the destination file, note the automatic reload, and warn that subscription updates replace local edits. The Add Rule form has a remembered 「位置」 picker: 最前面 (default) or MATCH 之前 (before the MATCH/FINAL fallback, keeping comments directly above it attached; appended when there is no fallback).

### Rule-provider and group editors

New rule providers default to `classical` matching with `yaml` format; YAML without an explicit behavior also defaults to `classical`, while explicitly configured behaviors are preserved.

### Inline fields

Editable values inside `PanelRow`s use the shared `panelField()` style: plain text field, trailing alignment, 6 × 3 pt padding on an inset `rounded.chip` fill, so editable values never look like read-only values. Fields that apply on Return (TUN DNS) say so in the section footer.

### Inline errors

Destructive confirmations (deleting profiles, rules, groups and rule sets, overwriting a locally modified subscription) never use system alerts: in a menu-bar panel an alert takes key focus, the panel closes, and the action is lost. `ConfirmationOverlay` draws inside the panel instead: a 72% canvas scrim that cancels on tap, a 290 pt raised card (panel fill, `rounded.panel`, hairline border, soft neutral shadow) with headline title, secondary message, and two large bordered buttons; 取消 takes ⎋, the destructive action uses semibold failure-red text and has no Return shortcut. Underlying content is disabled while it is shown, and switching tabs dismisses it. The panel-level error banner uses failure red at 10% opacity, tile corners, a red warning symbol, caption text, and native close/copy actions. Message text expands from two to twelve lines on click and supports text selection. Home core-state notices similarly distinguish starting, stopped, and failed states, with recovery actions where implemented.

Quiet successes use a panel-bottom toast: raised panel fill, tile corners, hairline border, soft neutral shadow, a green checkmark and caption text, shown for about two seconds, never taking focus or hit-testing, announced to VoiceOver, and faded (not moved) under Reduce Motion. It confirms copies (proxy command, error text, links, rules, node names), DNS cache flushes, and Geo/provider updates. Settings data actions show their progress in place of their own button, keeping its width, instead of a section-level spinner.

### Home route

The compact route ribbon on Home is a button: with a trailing chevron and tile hover highlight, it switches to 策略 and opens the primary group's detail (via `AppState.openGroupRequest`), so changing nodes is two clicks from Home.

## Do's and Don'ts

### Do:

- **Do** follow macOS appearance, native controls, SF Symbols, and system text hierarchy.
- **Do** reuse the established panel, tile, chip, and spacing values rather than introducing parallel scales.
- **Do** preserve visible text and state indicators alongside semantic network colors.
- **Do** distinguish untested latency, timeout, a stopped core, and a running core without traffic takeover.
- **Do** keep browser specimens explicitly labeled as representative native-component equivalents, not SwiftUI implementation code.

### Don't:

- **Don't** follow the user's system accent in place of the confirmed OrangePulse brand orange, or recolor semantic network states and traffic series as decorative accents.
- **Don't** turn the menu-bar interface into a main-window layout or add unsupported responsive breakpoints.
- **Don't** reintroduce glass backgrounds, saturated-orange selection fills, or decorative shadows; retain the shared fine outline and native dividers.
- **Don't** bypass the existing Reduce Motion checks on toggle, press, or hover feedback.
- **Don't** treat synthesized tonal ramps, browser focus styling, or browser component metrics as extracted shipping tokens.
