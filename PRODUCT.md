# Product

<!-- impeccable:product-schema 1 -->

## Platform

macos (native SwiftUI menu bar app; not one of web/ios/android/adaptive — follow macOS conventions)

## Users

Primarily the author themself: a technically fluent user who writes and edits mihomo configs, using TinyClash daily on their own Mac. No onboarding for newcomers is needed; screens serve fast, repeated operation.

## Product Purpose

A native macOS client for the mihomo core: use official mihomo YAML directly, add rules and strategy groups to that file, switch system proxy / TUN, pick nodes, and see what traffic is doing. Success is that everyday control takes seconds and the app's state is obvious at a glance.

## Operating Context

Most frequent surface: the menu-bar panel, used for system proxy and TUN toggles, mode switching, live traffic, and route status. The proxy tab is next for browsing groups, testing latency, and selecting nodes. Profiles and settings are occasional tasks. The Rules tab shows the currently loaded rules; deeper connection, rule-provider content, resource, and log inspection uses metacubexd or the core log file rather than a main window.

## Capabilities and Constraints

- System proxy via networksetup; TUN via a setuid-root core; mode, allow-LAN and TUN patched at runtime over the mihomo REST API.
- Profiles: subscriptions (usage/expiry, auto update) and local YAML. Adding, editing in place, or deleting rules and strategy groups validates and writes standard YAML directly to the selected profile's file; there is no separate custom-item manager. Subscription refresh replaces local edits. Legacy overlays remain readable and are folded into the file on the next successful edit.
- The menu-bar panel has five tabs: 首页 (proxy state, live traffic and route), 代理 (groups, latency tests, node selection, and adding/editing/deleting strategy groups directly in YAML), 配置 (subscriptions and local YAML), 规则 (currently loaded runtime rules in matching order, search, refresh, and adding/editing/deleting rules directly in YAML), 设置 (system, TUN, core and data actions). Detailed connections, rule-provider contents, resources and logs are opened in metacubexd or the core log file.
- UI language is Simplified Chinese.

## Brand Commitments

- Visual reference set by the user: Stash for Mac — its dashboard, node cards and latency testing, overall finish, and menu bar experience. The user asked for the familiar, competitor-like path ("现代一点 参考 stash"), so convention executed at Stash's craft level is the standing commitment.

## Product Principles

- State first: whether traffic is proxied, how, and through which node should be readable without interpretation.
- Seconds, not screens: the common actions live in the menu bar and need no window.
- Native over novel: standard macOS controls, materials and behaviour; polish lives in precise details.
- Never misrepresent the network: displayed status must reflect the core's real state.
