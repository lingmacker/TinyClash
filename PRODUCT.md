# Product

<!-- impeccable:product-schema 1 -->

## Platform

macos (native SwiftUI menu bar app; not one of web/ios/android/adaptive — follow macOS conventions)

## Users

Primarily the author themself: a technically fluent user who writes and edits mihomo configs, using TinyClash daily on their own Mac. No onboarding for newcomers is needed; screens serve fast, repeated operation.

## Product Purpose

A native macOS client for the mihomo core: use official mihomo YAML directly, add rules and strategy groups to that file, switch system proxy / TUN, pick nodes, and see what traffic is doing. Success is that everyday control takes seconds and the app's state is obvious at a glance.

## Operating Context

Most frequent surface: the menu-bar panel, used for system proxy and TUN toggles, mode switching, live traffic, and route status. The strategy tab is next for browsing groups, testing latency, selecting nodes, and inspecting sampled request routes. Profiles and settings are occasional tasks. The Rules tab shows the currently loaded rules; deeper connection, rule-provider content, resource, and log inspection uses metacubexd or the core log file rather than a main window.

## Capabilities and Constraints

- System proxy via networksetup; TUN via a setuid-root core; mode, allow-LAN and TUN patched at runtime over the mihomo REST API.
- Profiles: subscriptions (usage/expiry, auto update) and local YAML. Adding, editing in place, or deleting rules and strategy groups validates and writes standard YAML directly to the selected profile's file without auto-restarting the running core; the top status badge switches to "需重启生效" (clickable to restart once all edits are done) while the Proxies and Rules tabs stay synced with the updated YAML. There is no separate custom-item manager. Subscription refresh replaces local edits. Legacy overlays remain readable and are folded into the file on the next successful edit.
- The menu-bar panel has five tabs: 首页 (proxy state, live traffic and route), 策略 (groups, latency tests, node selection, adding/editing/deleting strategy groups directly in YAML, and in-panel sampled request logs with actual routing chains), 配置 (subscriptions and local YAML), 规则 (currently loaded runtime rules in matching order, refresh, and adding/editing/deleting rules directly in YAML), 设置 (system, TUN, core and data actions). Advanced connection controls, expanded rule-provider contents, resources and core logs are opened in metacubexd or the core log file.
- Rules includes an in-panel 规则集 manager for `rule-providers`: create, edit and delete HTTP, file and inline definitions directly in the selected YAML using the same strict validation and deferred-restart flow. Provider creation includes a target-policy picker (default DIRECT) and atomically validates/saves both the provider and a matching RULE-SET rule inserted first in rules. Configured group choices remain available when stopped. Editing a provider leaves existing routing references unchanged. Names are read-only when editing; deletion requires confirmation and keeps local files and referencing rules intact, so invalid references fail validation. Unsupported complex YAML is reported rather than silently rewritten. Runtime count and HTTP update time are shown only for the active, unchanged configuration; individual/all HTTP content updates do not rewrite YAML or restart the core. RULE-SET rule forms offer configured providers in a native picker. Stopped cores still permit definition edits; pending restart disables content updates and hides stale runtime metadata.
- 策略 → 请求日志 keeps up to 500 observed connections in memory, sampling the core's `/connections` WebSocket each second. Completed connections remain readable with their actual matched policy, full policy-to-outbound chain, rule and metadata; search covers host, process, route and rule. Clearing does not disconnect or re-add existing active connections. Switching profiles or restarting the core resets history. Sampling can miss short connections and does not enumerate individual HTTP requests on a reused connection; these limits are documented in README.md. Disconnects/invalid snapshots are reported, and stale callbacks from old core sessions cannot populate a new session's logs.
- UI language is Simplified Chinese.

## Brand Commitments

- Visual reference set by the user: Stash for Mac — its dashboard, node cards and latency testing, overall finish, and menu bar experience. The user asked for the familiar, competitor-like path ("现代一点 参考 stash"), so convention executed at Stash's craft level is the standing commitment.

## Product Principles

- State first: whether traffic is proxied, how, and through which node should be readable without interpretation.
- Seconds, not screens: the common actions live in the menu bar and need no window.
- Native over novel: standard macOS controls, materials and behaviour; polish lives in precise details.
- Never misrepresent the network: displayed status must reflect the core's real state.
