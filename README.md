# TinyClash

基于 [mihomo](https://github.com/MetaCubeX/mihomo) 内核的 macOS 菜单栏代理客户端（SwiftUI，macOS 14+）。没有主窗口，所有操作都在菜单栏面板里完成。

## 构建

```bash
./scripts/build-app.sh                       # 自动下载最新 mihomo 并打包；连不上 GitHub 时用缓存的内核
MIHOMO_VERSION=v1.19.34 ./scripts/build-app.sh
MIHOMO_BIN=/path/to/mihomo ./scripts/build-app.sh
open build/TinyClash.app
```

## 功能

菜单栏面板顶部显示当前配置和代理状态，下面分五页（⌘1–5 切换）：

- **首页**：系统代理 / TUN 开关、规则/全局/直连、当前出站路径（模式 → 分组 → 节点 · 延迟）、实时流量图、连接数/内存/累计流量/端口；复制终端代理命令、打开 Web 面板、重启内核；底部固定显示「配置文档」和「退出 TinyClash」
- **代理**：策略组列表（当前节点、延迟健康条）→ 进入分组选节点、单个或整组测速；支持「添加策略组」（标准多行块级 YAML 格式）、在列表右键菜单或详情页点击编辑图标进入原位编辑（名称只读，保留 `use`、`lazy` 等其余 YAML 字段）及删除策略组，均经 `mihomo -t` 校验后直接写入当前配置的 YAML
- **配置**：切换配置；添加订阅（解析 `subscription-userinfo` 流量/到期、自动更新）、导入本地 YAML、新建空白配置、外部编辑后重载、删除
- **规则**：通过 `/rules` 显示当前内核已加载的规则，按匹配顺序展示类型、内容、目标策略；支持刷新、「添加规则」、点击规则行进入原位编辑（保留匹配顺序与行尾注释，支持页内删除）及右键菜单删除规则，校验通过后直接写入当前配置的 YAML。RuleSet 条目显示集合引用，不展开集合内部内容
- **设置**：登录时启动、菜单栏网速、TUN 授权/协议栈/DNS、绕过地址、测速、内核管理、更新规则集/代理集合/Geo 数据库、清空 DNS 缓存

连接列表、规则集合内部条目、资源详情和日志可点首页的「Web 面板」用 metacubexd 查看；内核日志文件在 设置 → 内核 菜单中打开。

## 设计说明

- **完全使用官方配置**：使用 mihomo 官方 YAML 格式（`-d <工作目录> -f <配置>`），不转换为 App 私有配置。通过命令行 `-ext-ctl/-secret` 指定控制接口，并通过 REST API 在运行时覆盖模式、局域网、TUN 开关。只有明确执行增删改规则、增删改策略组或外部编辑时才修改配置内容。
- **增删改规则 / 策略组**：分别在「规则」「代理」页内直接添加、点击原位编辑或删除，修改当前配置文件（应用内的 YAML 副本），没有单独的自定义内容管理。新增规则插入 `rules` 最前面，新增策略组以标准多行 YAML 格式追加到 `proxy-groups` 末尾；原位编辑会保留规则顺序与行尾注释，以及策略组中表单未覆盖的字段（如 `use`、`lazy`），策略组编辑时名称保持只读以避免引用失效。每次增删改都用 `mihomo -t` 校验通过后才写入，失败（如策略组仍被规则引用）不修改原文件。运行中增删改规则或策略组时不会自动重启内核，顶部状态会变为「需重启生效」，界面列表与策略下拉同步反映当前 YAML；全部改完后点击顶部「需重启生效」或首页「重启内核」即可一次性生效（停核时只保存）。**订阅更新会覆盖本地修改**，需要长期保留时建议使用本地配置。旧版已保存的叠加内容继续兼容，并在下次增删改时一并迁移到所选配置、清除对应旧记录。后续更复杂的编辑也可在「配置 → … → 在编辑器中打开 YAML」进行。
- **系统代理**：通过 `networksetup` 设置所有已启用网络服务的 HTTP/HTTPS/SOCKS 代理；端口取配置中的 `mixed-port`/`port`/`socks-port`。关闭时只清除仍指向本 App 端口的设置。
- **TUN**：需要 root 运行内核。首次开启时请求管理员授权，把内核设为 `root:admin` 并加 setuid 位；之后通过 `PATCH /configs {"tun":{"enable":true}}` 开关。其他 TUN 参数沿用配置文件的 `tun` 字段，建议配置启用 `dns`（fake-ip）。可在设置中撤销授权。
  - **安全限制**：当前采用开发阶段的 setuid 方案，不是经过加固的特权辅助进程。内核位于用户可写目录，且接受外部配置路径；本机其他进程可能借此获得 root 权限。不要把它视为可安全分发的权限设计，正式分发前应替换为权限范围受限、可验证调用方的特权服务。
- **节点数据**：`proxy-providers` 里的节点不会出现在 `/proxies`，App 会从 `/providers/proxies` 合并；延迟同时读取默认测速地址的 `history` 和各分组测速地址下的 `extra[url].history`。

## 开发用启动参数

仅用于截图检查界面，需要用预览构建启用临时窗口（正式构建不包含预览窗口）：

```bash
TINYCLASH_PREVIEW=1 ./scripts/build-app.sh
open build/TinyClash.app --args -uiPanelPreview YES   # 在普通窗口中显示面板
  -uiTab home|proxies|profiles|rules|settings                # 初始标签页
  -uiOpenGroup <分组名>                                 # 直接打开某个分组
  -uiCycleTabs YES                                      # 内核就绪并测速后依次切换标签页
  -uiAppearance light|dark                              # 强制外观
```

## 数据目录

`~/Library/Application Support/com.tinyclash.app/`：`core/mihomo`（内核）、`mihomo/`（内核工作目录）、`profiles/`、`runtime/`、`logs/core.log`
