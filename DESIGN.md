---
name: TinyClash
description: Stash-inspired, restrained native macOS menu-bar controls for mihomo.
colors:
  canvas-light: "rgb(95.5% 96% 97%)"
  canvas-dark: "rgb(10.5% 10.8% 11.8%)"
  panel-light: "rgb(100% 100% 100%)"
  panel-dark: "rgb(16.5% 16.8% 18%)"
  inset-light: "rgb(0% 0% 0% / 4%)"
  inset-dark: "rgb(100% 100% 100% / 6%)"
  chart-label-light: "rgb(36% 36% 36%)"
  chart-label-dark: "rgb(75% 75% 75%)"
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
    padding: "2pt 6pt"
  route-segment:
    rounded: "{rounded.chip}"
    padding: "4pt 8pt"
  route-segment-compact:
    rounded: "{rounded.chip}"
    padding: "3pt 6pt"
  node-row:
    rounded: "{rounded.tile}"
    height: "42pt"
    padding: "0pt 10pt"
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

- **OrangePulse accent** (`Theme.accent`, `#F57B3F`): retained for the app mark, native controls (switches, checkboxes, progress), and selected node/profile indicators, but never as small text: on the light canvas it measures only ~2.6:1. Text actions (list-toolbar primaries, subpage 返回/保存/添加) use `Theme.accentForeground` through the shared `toolbarAction` style; secondary toolbar actions use primary text, and every toolbar action shows icon plus label. Small warning text (expiry, 「本地已修改」, the 「需重启生效」 pill, subscription-overwrite notices) uses `Theme.warningText`: dark orange `#9E5400` in light appearance, system orange in dark; with `Theme.accentHighlight` (`#FF9661`) supplying the light end of the app mark's pulse gradient. Large selected surfaces no longer use saturated orange. Tabs, enabled toggle tiles, selected mode segments, the header quit action, and the prominent Profiles footer action share opaque `Theme.controlFill`: pale apricot `#FCE9DD` in light appearance and muted warm brown `#493429` in dark appearance. Their adaptive `Theme.accentForeground` is dark warm orange `#8C431C` / soft apricot `#FFD3B7`, maintaining at least 4.5:1 contrast. Enabled toggle icon circles use this foreground at 8% opacity. Selected node rows retain accent at 12% opacity, and the terminal route segment uses 14%.

### Secondary

- **Download blue** (`NSColor.systemBlue`): download labels and the download chart series.
- **Upload teal** (`NSColor.systemTeal`): upload labels and the upload chart series.

### Tertiary

- **Active green** (`NSColor.systemGreen`): traffic takeover status and successful latency readings below 500 ms.
- **Warning orange** (`NSColor.systemOrange`): starting state, pending-restart state (“需重启生效”), and latency from 500 ms up to, but not including, 1000 ms.
- **Failure red** (`NSColor.systemRed`): core failure, timeout, error notices, and latency of 1000 ms or more.

These native semantic colors deliberately have no fabricated fixed hex tokens or synthesized tonal ramps. The platform resolves their actual values.

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

- **Panel and compact surface:** no added shadow; a 0.5 pt outline uses white at 10% opacity in dark appearance and black at 6% in light appearance.

The sidecar preserves these native expressions. Its browser specimens use representative CSS shadows, not an assertion that SwiftUI blur radius and CSS blur are identical.

### Named Rules

**The Raised Panel Rule.** Reuse opaque tonal surfaces and the shared half-point outline for cards; do not reintroduce translucent materials or stack decorative shadows on top. Retain native dividers and field borders where the component already uses them.

## Shapes

- **Panel:** large continuous rounded corners (`rounded.panel`) for traffic and group cards.
- **Tile:** tighter continuous rounded corners (`rounded.tile`) for proxy toggles, action tiles, tabs, node rows, rule cards, and inline error notices.
- **Section:** grouped settings containers derive their radius from tile plus 2 pt (`rounded.section`).
- **Route chip:** small continuous rounded corners (`rounded.chip`), not a capsule.
- **Capsule:** tags and status badges. Tags use 12% tinted fill; status badges use a 7 pt dot and 8 pt horizontal / 3 pt vertical padding. Latency dots and health-strip marks are 6 × 6 pt; health strips have 3 pt gaps, show at most 28 marks, and append a text overflow count.

## Components

### Toggle tiles and action tiles

`ToggleTile` is a large labeled action, not a native switch. Its enabled state uses the soft adaptive apricot control fill and contrasting warm content; off uses inset fill and primary/secondary text. A 32 pt icon circle holds a symbol or small progress indicator. While working it rejects repeated actions; externally unavailable tiles have 50% opacity. Its accessibility label and on/off value are explicit.

Home action tiles use raised panel fill, a symbol over a caption-sized label, and the compact shadow. Disabled action tiles use 45% opacity. Both tile families use `PressableStyle`: 0.98 pressed scale and 85% pressed opacity, with ease-out over 0.12 s. With Reduce Motion, that style suppresses animation and scaling but retains opacity feedback.

`hoverHighlight` overlays primary text color at 4.5% opacity, with ease-out over 0.12 s unless Reduce Motion is enabled. It is applied to action tiles, proxy cards, and rule cards, not universally to every control. Toggle on/off fill changes separately animate over 0.18 s, with that animation disabled when Reduce Motion is enabled.

### Native controls and fields

Home uses a native segmented picker for mode selection. Group search uses `TextField` with `.roundedBorder`, shown only when a group has more than ten members. Test actions use native borderless buttons, latency actions use plain buttons, and the empty-state import action uses `.borderedProminent`. Preserve those platform treatments; the inspected code provides no custom focus ring or custom text-field error style.

The Profiles footer uses explicit 24 pt-high controls with 8 pt horizontal padding, 4 pt icon-label spacing, and an 8 pt vertical footer inset instead of small native tinted buttons. “添加订阅” uses the shared soft apricot control fill and contrasting warm text; “导入文件” and the more-actions menu use opaque native control-background fill with primary text. All three use caption semibold labels/icons and the shared chip radius. The more-actions menu keeps “更新全部订阅” disabled without remote subscriptions, without an extra explanatory menu row. The node-update action has no hover tooltip. Each profile card's menu additionally offers “更新订阅节点” for the selected, running configuration, including local YAML: it updates only HTTP `proxy-providers`, shows an in-card progress indicator, then refreshes the node list without rewriting YAML, restarting the core, or updating rule providers. Noncurrent/stopped profiles show “请先切换到此配置并启动内核”; enumeration errors, absent HTTP subscriptions, and individual update failures are reported rather than silently treated as success.

### Tags and status

`Tag` uses caption2 medium text, tinted foreground, a 12% tinted capsule, and compact padding. `StatusBadge` pairs text with its semantic dot: running and proxying is green “接管中”, with an opaque pale-mint background (`#DCEEE2`) and dark-green text/dot (`#145C2F`) in light appearance, and an opaque dark-green background (`#183D26`) with soft-mint text/dot (`#A7E5BA`) in dark appearance, keeping contrast stable in both appearances; running with pending YAML edits to rules or strategy groups is an orange clickable “需重启生效” pill that restarts the core on click; applying pending changes or restarting shows orange “重启中” (not clickable); quitting shows secondary “关闭中” while the header 退出 action dims and disables; running without takeover and stopped are secondary; starting is orange; failure is red. A running core alone does not imply active traffic takeover.

### Navigation

The five equal-width tabs (首页, 策略, 配置, 规则, 设置) pair SF Symbols with caption2 medium labels. Active tabs use opaque soft apricot (`Theme.controlFill`) with contrasting warm (`Theme.accentForeground`) icons/labels; inactive tabs use primary text on clear fill. They use `PressableStyle`, expose selection to accessibility, and support Command–1 through Command–5. Subpage headers use a native borderless “返回” action with the cancel keyboard shortcut. The shared header's “退出” action uses the same adaptive soft control fill and warm text/power icon as the selected tabs. Home has no footer: 退出 lives in the shared header and the mihomo configuration-docs link lives in Settings → 内核与数据 → mihomo menu.

### Panels and proxy groups

`PanelBackground` supplies the reusable raised card. Group cards contain a semibold group name, a type tag, a secondary current-route label that resolves nested group selections to the final node (`节点选择 › 自动选择 › 节点`, head-truncated) with that node's latency (or “待重启生效” for newly added groups before restart), a latency reading, and a decorative health strip. Clicking a group opens its in-panel detail, where newly added groups pending restart disable latency testing and manual node switching with an explanatory notice until the core restarts. The Proxies toolbar keeps “添加策略组” visible even while the core is stopped or in direct mode, provided a profile is selected. Additions, in-place edits (via card context menu or detail header edit icon for non-`GLOBAL` groups, keeping the name read-only and preserving unmanaged YAML keys), and deletions (via card context menu, the detail header ⋯ menu, or edit page trash action, each confirmed first) validate and write standard multi-line YAML to that profile's file and defer core restart to the header “需重启生效” action; no custom-group manager or badges are shown. Rules are added, edited, and deleted directly from Rules, not Settings. While testing, test actions keep their footprint: the label hides and a small progress indicator sits in its place, so neighbouring header buttons never shift; do not style it as a completed measurement. 「测速」 on the group list tests up to four groups concurrently. The group detail header carries only two actions: 测速 and a ⋯ menu holding 按延迟排序, 编辑策略组… and 删除策略组…. Node rows show a protocol subtitle only when the group mixes protocols (built-in DIRECT/REJECT excluded); otherwise rows are single-line.

### Route ribbon

`RouteRibbon` shows the resolved group/node chain and the final node's latency when available. The noncompact variant also shows mode; the compact variant omits that redundant chip because the segmented picker already shows the selected mode. Secondary segments use inset fill; the last segment uses primary 13 pt semibold text on 14% accent fill and retains layout priority 1. Small tertiary chevrons separate segments. Direct mode explicitly says all traffic is direct; empty chains use loading or empty-state copy instead of inventing a route.

### Node rows

Rows use the fixed `node-row` height. Selection combines an accent checkmark, semibold name, and 12% accent background. Hover supplies inset fill only for selectable groups. A trailing latency action changes to a mini progress indicator during testing. Nonselectable automatic groups retain their informational row and explain why manual selection is unavailable.

### Menu bar speed

`MenuBarSpeedImage` follows TinyNet's two-line template-image approach rather than a variable-width SwiftUI text label. Upload (`↑`) is above download (`↓`), using 8 pt bold system monospaced text, right-aligned within a fixed 66 × 22 pt speed column. The existing 18 pt active/idle status mark is centered vertically to its left with a 4 pt gap, producing one 88 × 22 pt template image. AppKit supplies display-scale rasterization and system menu-bar tinting. The input remains mihomo bytes/s, displayed from KB/s upward using binary conversion, two decimals and a minimum six-character numeric field; units extend through EB/s to keep extreme values within the fixed column. An image is reused while formatted text and proxy status remain unchanged. Disabling menu-bar speed or stopping the core restores the original status icon without a speed column; the Home chart formatter is unchanged.

### Traffic readouts and chart

The Home card pairs blue download and teal upload labels with numeric readouts. Speed text uses `.numericText()` transitions. Its native Swift Charts plot is at least 72 pt high and grows to absorb the panel's remaining height, so Home never leaves empty space below the quick actions (when the core is not running and the chart is absent, the quick actions sit at the bottom instead); the content still scrolls when an error banner pushes it past the panel, with monotone interpolation and 1.4 pt line strokes. Only download has an area fill, fading from 30% to 2% opacity. The horizontal axis and legend are hidden; the trailing vertical axis requests two speed labels with dashed half-point grid lines. History-count changes explicitly disable chart animation. These are observations of the existing chart, not additional chart tokens or new visualization design.

### Runtime rules

The Rules tab mirrors Proxies' card-list structure: its toolbar shows the rule count (with a tooltip noting matching order and unexpanded RuleSet references), a refresh action, and a visible “添加规则” action (with no custom-item management menu). Rule types display in their YAML spelling (`DOMAIN-SUFFIX`, `IP-CIDR`, `GEOIP` with upper-case country codes), not the core's runtime names, so the list matches the editor and the file. Each rule renders as an individual compact raised two-row card (`RuleCard`, `rounded.tile` corners, `s` vertical stack spacing, `hoverHighlight`, and `PressableStyle`) so varying rule-type widths never stagger the match content: the top row aligns the middle-truncated match content on the left with a trailing chevron on the right, and the bottom row aligns the rule type `Tag` on the left with the semantic destination policy (`DIRECT` green, `REJECT` red, proxy groups accent) on the right; clicking a card opens an in-panel editor prefilled from the profile YAML (preserving order, inline comments, and extra options, with a header trash action), and a context menu offers edit, copy payload/policy, and direct deletion after `mihomo -t` validation. `LazyVStack` keeps longer configurations scrollable. Collection references remain references, not invented expanded lists. The page has explicit loading, stopped, empty, error/retry, and non-rule-mode states; rule creation and editing stay in-panel. Adding, saving, or deleting validates and persists directly to YAML without automatically restarting a running core—marking the header badge “需重启生效” and switching the list source to the updated YAML until the user restarts. Forms explain the destination file, note the deferred restart, and warn that subscription updates replace local edits.

### Inline errors

Destructive confirmations (deleting profiles, rules, groups and rule sets, overwriting a locally modified subscription) never use system alerts: in a menu-bar panel an alert takes key focus, the panel closes, and the action is lost. `ConfirmationOverlay` draws inside the panel instead: a 72% canvas scrim that cancels on tap, a 290 pt raised card (panel fill, `rounded.panel`, hairline border, soft neutral shadow) with headline title, secondary message, and two large bordered buttons; 取消 takes ⎋, the destructive action uses semibold failure-red text and has no Return shortcut. Underlying content is disabled while it is shown, and switching tabs dismisses it. The panel-level error banner uses failure red at 10% opacity, tile corners, a red warning symbol, caption text, and native close/copy actions. Message text expands from two to twelve lines on click and supports text selection. Home core-state notices similarly distinguish starting, stopped, and failed states, with recovery actions where implemented.

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
