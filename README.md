# TinyClash

基于 [mihomo](https://github.com/MetaCubeX/mihomo) 内核的 macOS 原生代理客户端（SwiftUI，macOS 14+）。

## 构建

```bash
./scripts/build-app.sh                       # 自动下载最新 mihomo 并打包
MIHOMO_VERSION=v1.19.34 ./scripts/build-app.sh
MIHOMO_BIN=/path/to/mihomo ./scripts/build-app.sh
open build/TinyClash.app
```

## 功能

- 菜单栏：系统代理 / TUN 开关、规则/全局/直连、策略组选节点与测速、切换配置、复制终端代理命令、打开 Web 面板（metacubexd）、网速显示
- 主界面：概览（实时流量图、总量、内存、连接数）、代理、配置、连接、规则、资源（proxy/rule providers、Geo 数据库、DNS 缓存）、日志、设置
- 配置：订阅链接（解析 `subscription-userinfo` 流量/到期、自动更新）、导入本地 YAML、新建空白配置、外部编辑后重载；导入时用 `mihomo -t` 校验
- 开机启动、退出/崩溃时自动恢复系统代理和 DNS

## 设计说明

- **完全使用官方配置**：配置文件原样传给内核（`-d <工作目录> -f <配置>`），App 只通过命令行 `-ext-ctl/-secret` 指定控制接口，并通过 REST API 在运行时覆盖模式、局域网、TUN 开关。文件本身不会被改写。
- **自定义规则 / 分组**：在「规则」「代理」页面添加，按配置分别保存在 `profiles.json`。启动时生成 `runtime/<配置>.yaml`：自定义分组追加到 `proxy-groups` 末尾，自定义规则插入到 `rules` 最前面；原配置不变，订阅更新后依然生效。保存前会用 `mihomo -t` 校验。
- **系统代理**：通过 `networksetup` 设置所有已启用网络服务的 HTTP/HTTPS/SOCKS 代理；端口取配置中的 `mixed-port`/`port`/`socks-port`。关闭时只清除仍指向本 App 端口的设置。
- **TUN**：需要 root 运行内核。首次开启时请求管理员授权，把内核设为 `root:admin` 并加 setuid 位；之后通过 `PATCH /configs {"tun":{"enable":true}}` 开关。其他 TUN 参数沿用配置文件的 `tun` 字段，建议配置启用 `dns`（fake-ip）。可在设置中撤销授权。
  - 注意：setuid 内核意味着本机任何进程都能以 root 运行它，这与 Clash Verge 的做法相同，适合个人设备。

## 数据目录

`~/Library/Application Support/com.tinyclash.app/`：`core/mihomo`（内核）、`mihomo/`（内核工作目录）、`profiles/`、`logs/core.log`
