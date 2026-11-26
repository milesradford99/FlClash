# FlClash ISP 构建与验收

FlClash ISP 使用独立的 macOS App 标识 `com.milesradford99.flclash.isp`。日常使用安装一个 `FlClash ISP.app`，由同一个 Mihomo Core 处理 TUN、指定应用分流和 Chrome 的固定 ISP 入口。全机网络保护是单独构建的测试模式，签名及验收见[全机网络保护](#全机网络保护)。

## 本机签名与打包

在构建 Mac 上安装完整 Xcode、Flutter 3.50.0、Go 1.27 和 Rust。从本项目 `main` 构建，先取回锁定的子模块版本。框架、Core 和 App 按从内到外的顺序签名。用 Xcode 的「Settings → Accounts → Manage Certificates」准备 `Apple Development` 签名证书即可在本机测试组合模式。首次开启 TUN 时，App 会核对包内 Core 与 App 的团队标识是否相同，再请求 macOS 管理员授权。[Apple 签名证书管理](https://developer.apple.com/documentation/xcode/sharing-your-teams-signing-certificates)

```bash
git -c url.https://github.com/.insteadOf=git@github.com: submodule update --init --recursive
flutter pub get
flutter build macos --release --no-pub \
  --dart-define=APP_ENV=stable \
  --dart-define=FLCLASH_REPOSITORY=milesradford99/FlClash \
  --dart-define=MANAGED_ISP_PROTECTION=false
security find-identity -v -p codesigning
```

在下一段把 `identity` 改为上一步列出的 `Apple Development` 证书 SHA-1。使用 Bash 或 Zsh 执行。构建输出对应当前构建机的架构。

```bash
identity='<Apple Development 证书 SHA-1>'
output="$(mktemp -d "${TMPDIR:-/tmp}/flclash-isp.XXXXXXXX")"
app="$output/FlClash ISP.app"

ditto build/macos/Build/Products/Release/FlClash.app "$app"
while IFS= read -r -d '' item; do
  codesign --force --sign "$identity" "$item"
done < <(find "$app/Contents/Frameworks" -maxdepth 1 \( -name '*.framework' -o -name '*.dylib' \) -print0)

codesign --force --sign "$identity" --identifier com.milesradford99.flclash.isp.core \
  "$app/Contents/MacOS/FlClashCore"
codesign --force --sign "$identity" --entitlements macos/Runner/Release.entitlements "$app"
codesign --verify --deep --strict "$app" &&
  ditto -c -k --keepParent "$app" "$output/FlClash-ISP-macOS.zip" &&
  shasum -a 256 "$output/FlClash-ISP-macOS.zip"
```

将 ZIP 解压到「应用程序」，再打开 App 并完成 TUN 授权。开发签名用于本机验收。对外分发给其他 Mac 时按 Apple 流程使用 Developer ID 签名与公证。[Apple 独立分发签名指南](https://developer.apple.com/documentation/xcode/creating-distribution-signed-code-for-the-mac/)

## 使用单 App

1. 在同一台 Mac 上先退出原版 FlClash 并关闭它的 TUN。在 FlClash ISP 进入「配置 → 添加 → 配置 VPN 和固定 ISP」，粘贴 HTTPS 订阅与 `socks5://user:password@host:port`。可选填预期公网出口 IP。SOCKS5 凭据保存在系统钥匙串，对应的运行配置文件权限为 `0600`。
2. 启用固定 ISP 配置并按提示授权 TUN。在「代理」的「共享 VPN 节点」选一次节点。普通应用继续按原订阅规则分流，引用受支持内联 VPN 节点的规则使用这个选项。外部代理提供商及未参与共享的自定义出站仍按订阅处理。
3. 用「用固定 ISP 打开 Chrome」选择浏览空间，或从「检查 macOS 和 Chrome → 指定应用」添加本机 App 或独立可执行文件。Chrome 通过专用本地端口 `127.0.0.1:17890`，匹配的 App 主程序和包内 Helper 的新 TCP 连接也走同一条 VPN → ISP。匹配的 UDP 被拒绝。启动新连接后可以在「指定应用」中核对命中；外部浏览器、Git、SSH、MCP 和系统 DNS 以实际发起连接的进程为准。

### 故障切换与定时检查

Core 在 ISP 出站拨号失败，或连接尚未收到首批数据时读失败，先验证当前链路。确认失败后每批最多并发检查三个 VPN → ISP 候选，优先检查近期成功过的节点，在首批通过的候选中按延迟选择。填写预期出口 IP 时，切换前也会核对该 IP。

全部失败时进入 30 秒到 5 分钟的递增冷却。固定 ISP 流量会报错，普通应用继续按订阅分流。切换只更新共享 VPN 节点，保留已有连接。

「检查 macOS 和 Chrome → 链路检查设置」中的定时检查默认关闭。开启后默认每 120 秒检查一次，可自定义间隔。近期有固定 ISP 连接活动时才探测当前链路，确认失败后再检查候选。

### 单 App 验收

| 操作 | 预期结果 |
| --- | --- |
| 启用 TUN，从非指定应用访问订阅允许的目的地 | 仍按订阅的 VPN、直连或拒绝规则处理。 |
| 同时打开两个固定 ISP Chrome 空间，另选一个本机 App 发起新连接 | Chrome 空间分别保存登录和 Cookie；被选应用命中规则，这些新 TCP 连接共用一个 ISP 出口。 |
| 切换一次「共享 VPN 节点」 | 使用该选项的普通 VPN 和固定 ISP 新连接均切换，固定 ISP 公网出口保持一致。 |
| 在可控环境断开当前 VPN 节点，或让整个 ISP 出口停止 | 有健康候选时，新连接改走新 VPN 节点和同一个 ISP；ISP 出口不可用时，固定 ISP 新连接报错。切换前已建立、且上游仍然可用的普通 TCP 连接继续工作。 |
| 在定时检查关闭与开启状态下分别观察空闲和活跃时段 | 关闭时保留故障触发检查。开启时按设定间隔检查近期活跃的当前链路。 |

排查卡顿时，用相同 VPN 节点和 ISP 出口，对照指定应用 TUN 与专用本地代理访问同一 HTTPS 端点，记录建连、TLS、首包和复用连接耗时。当前健康检查使用 Cloudflare HTTPS 探测。某个业务 API 在已收到数据的连接上读超时，可能不会触发自动复查。应用日志里的超时和出口检查应一起看。

## 检查 macOS 和 Chrome

保存固定 ISP 配置后会显示常用操作，也可从固定 ISP 卡片的设备图标重新打开。在「用固定 ISP 打开 Chrome」下选择一个空间，也可以新建或改名。原有的「Chrome ISP」空间直接沿用。各空间可以同时打开，标签页、登录和 Cookie 分别保存，窗口共用当前选中的固定 ISP。FlClash 确认 TUN 和专用入口就绪后才启动 Chrome，并设置本机 SOCKS5 代理和 WebRTC 启动参数。组织策略及 WebRTC 实际路径可以在高级诊断中检查。

首页显示连接、Chrome 和 WebRTC 系统策略状态。点击 WebRTC 的「系统策略未设置」可打开安装入口，再在 macOS「通用 → 设备管理」确认。已有受管策略时提供核对入口。点语言或时区行可打开 macOS 设置。更换系统设置后，切回 App 会重新读取。只读检测不会启动代理或浏览器。以下手动验收流程在「高级诊断」中，组合版显示实际 TUN 状态，全机过滤器检查标为不适用。

1. 选择 Chrome Profile，或用「Chrome Profile · +」进入 Chrome 的创建流程。对照目标窗口 `chrome://version` 的 Profile Path 后，回到检测页确认。快捷入口可以打开目标 Profile 的策略、语言和安全 DNS 页面，另有 macOS 语言与地区、日期与时间设置入口。
2. 在目标 Profile 的 `chrome://policy` 重新加载策略，导出 JSON 文件后在检测页导入，也可复制 JSON 后用剪贴板导入。检测页只保留 WebRTC、DoH 和必要的来源元数据。策略缺失时「一键配置」会预览并打开现有系统级 WebRTC 描述文件，用户在设备管理中确认安装。已有其他受管值时，先处理冲突。回滚时在设备管理中移除本工具的「FlClash ISP Chrome WebRTC」，重新检测并导入策略。Chrome 安全 DNS 配置由用户在 Chrome 中查看和决定。
3. 主动测试需要授权端点。固定 ISP 已运行时，输入 HTTPS 端点并确认，只通过当前代理端口发送测试请求。测试端点可返回纯 IP、JSON 的 `ip` 字段或带 `ip=` 的文本。全机保护模式还会尝试系统解析。Chrome 探测页由所选 Profile 打开，按需输入允许跨域读取的 HTTPS 端点和受控 STUN/TURN，再手动运行并把结果贴回 App。探测页只回传完成状态、浏览器时区和候选分类计数。

策略预检、Chrome 生效策略、HTTPS、系统 DNS、ICE 候选和外部出口证据分别记录。Chrome 探测页的 HTTPS 成功或 ICE 收集完成需要结合受控端日志、对照和外部抓包，才能验证 DNS 实际出口、WebRTC 旁路或全机断网。涉及未提供的证据，结果保持「未验证」。

## 全机网络保护

这个单独构建的模式面向 macOS 15 及以上。请在有本地控制台的独立测试 Mac 上使用。

### 构建带过滤器的安装包

在独立构建 Mac 上准备完整 Xcode、Flutter 3.50.0、Go 1.27、Rust 和 Python 3，初始化 fork 的子模块。先在 Apple Developer 账号里准备 Developer ID Application 签名证书和以下两个 Developer ID provisioning profile。

| Bundle ID | Apple 能力 |
| --- | --- |
| `com.milesradford99.flclash.isp` | System Extension 安装权限、Network Extensions 的 Content Filter |
| `com.milesradford99.flclash.isp.filter` | Network Extensions 的 Content Filter |

使用同一 Apple Team 给 App、Core 和扩展签名。如果 Apple 账号需要另一组 bundle ID，构建前改 `macos/Runner/Configs/AppInfo.xcconfig`，并为新 App ID 和其 `.filter` 子 ID 准备描述文件。Intel 和 Apple Silicon 分别在相应架构的构建机上打包。

```sh
git -c url.https://github.com/.insteadOf=git@github.com: submodule update --init --recursive
tool/package_managed_macos.sh TEAM_ID 'Developer ID Application: Your Name (TEAM_ID)' \
  /path/to/host.provisionprofile /path/to/filter.provisionprofile
```

脚本构建应用、嵌入 Network Extension、用对应描述文件签名，并在 `dist/flclash-isp.*/` 输出 `FlClash-ISP-macOS.zip` 与 SHA-256。可在构建机上预先配置 `notarytool` 的钥匙串记录，并通过环境变量 `MANAGED_NOTARY_PROFILE` 指定记录名称。脚本会提交公证、装订票据并重新打包。凭据和 provisioning profile 仅留在构建机。 [Apple Network Extensions 签名要求](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.networking.networkextension) · [Apple 直接分发公证](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution)

### 使用和恢复

1. 在测试机将签名构建放到“应用程序”，打开后进入「配置 → 添加 → 配置 VPN 和固定 ISP」。粘贴 HTTPS 订阅 URL 和 `socks5://user:password@host:port` 连接串。可填写预期公网出口 IP，应用会比较检测结果。
2. 保存后有两个入口。「纯 VPN」按原订阅的节点、分组和规则运行。`01 VPN → ISP` 从同一份订阅生成出站链路。每个候选使用一个上游节点连接同一个 SOCKS5。健康检查经整条链路访问 HTTPS。
3. 点击 `01`。按 macOS 提示完成 FlClash TUN 所需授权及网络过滤系统扩展的批准。应用等待包过滤器和连接过滤器确认，再提交专用 Rule 和 TUN 配置。系统扩展通过经过签名校验的本地连接接收 VPN 节点地址，所有物理接口只允许明确的 VPN 拨号地址和 IPv4 DHCP 广播。应用不用访问生产业务网站即可检查出口，卡片会显示观测到的 IP 或「等待固定出口」。
4. 手动同步可在任一关联 profile 的菜单中执行。自动更新复用订阅的更新周期。保护模式中通过当前 ISP 链路下载和解析新订阅。下载或校验失败时保留旧版本。所有旧 VPN 地址都失效且当前链路不可用时，业务继续阻断，恢复方式是在测试机上明确选择「纯 VPN」后同步，再重新启用 `01`。
5. 正常退出保护时选择对应的「纯 VPN」。应用先停止监听并关闭旧连接，随后撤销该网络过滤配置，再启用原订阅。退出 App 或停止内核时，过滤配置继续保留。如果 App 无法操作，从本地控制台在 macOS「网络 → VPN 与过滤器」中关闭 FlClash ISP Network Filter，再复查网络。关闭过滤器就退出了系统保护。远程验收时确保有人可以使用本地控制台。

当前 `01` 支持带内联 `proxies` 的 Clash/mihomo 订阅和能解析为 IPv4 的上游。已有上游拨号链、仅外部 `proxy-providers`、端口跳跃节点及仅 IPv6 的节点需另行适配。宿主机 IPv6 业务和普通 UDP 不进入此 TCP SOCKS5 方案。订阅管理和更新在应用层完成，钥匙串保存 ISP 凭据与对应订阅快照标识。运行中的 Core 用权限为 `0600` 的配置文件接收凭据。更新包或迁移到另一台 Mac 后，如钥匙串记录缺失，重新输入凭据。订阅 URL 仍按 FlClash 的 URL profile 方式保存。

### 全机保护放行条件

先在同一测试网络确认 HTTPS、IPv6、DNS 和 UDP 都能到达受控目的地。用测试订阅和测试 ISP，并在测试 Mac **以外** 的设备上持续抓取该 Mac 的出站包。只看浏览器打不开网页不构成通过。系统启动、模式切换和网络改变时，用外部时间戳记录整个窗口。验收过程中避免把含订阅令牌、账号或真实 IP 的记录上传到公开仓库。

| 涵盖场景 | 必须观察到 |
| --- | --- |
| 从新机器配置两份 profile | 纯 VPN 复现原订阅的分流规则。01 业务流量显示固定 ISP，测试 DNS 同样经该链路。 |
| 更新和重启 | 增删和改名节点随刷新变化。下载或校验失败时保持上次可用订阅快照。重启之后 01 重新建立链路。 |
| 当前节点断开 | 可以切换到其他候选。现有及新业务连接的公网出口均为同一个 ISP。 |
| VPN 全断、ISP 停止或拒绝认证 | 业务 HTTPS、DNS、IPv6 和 UDP 没有未经授权的物理出站。UI 显示等待固定出口。 |
| 停止监听、强退界面或内核 | 过滤策略仍生效。旧 TCP、持续 UDP、QUIC 及绑定物理网卡的连接都无法绕过保护。 |
| 系统扩展异常、冷启动未登录、换网、唤醒和多网卡 | 从外部持续观测。任何未授权业务包都算失败。尤其记录系统扩展还未运行的阶段及重载期间。 |
| 应用在工作时，其他进程直拨 VPN 允许的 IPv4 和端口 | 普通应用被连接过滤器阻断。测试启动过滤器前已经建立的连接，也要使用同样的端点进行对照。 |
| 主动切到关联纯 VPN | 只有在明确切换后才允许原订阅的流量策略。该切换后可观察到原订阅允许的出口。 |

测试环境没有公网 IPv6、没有产生基线流量，或没有连续覆盖冷启动时，对应结果应记为未验证。macOS 过滤器被管理员从系统设置关闭的场景属于主动撤销保护，并应单独检查 App 的提示和恢复。Apple 的 API 文档并未承诺所有启动和故障窗口的行为。发布严格断网保护前，需要上述用例的实际记录。 [Apple 流量过滤 API](https://developer.apple.com/documentation/networkextension/content-filter-providers) · [系统扩展部署说明](https://developer.apple.com/documentation/technotes/tn3134-network-extension-provider-deployment)

## 无需启动 App 的源码检查

```sh
flutter pub get
flutter analyze --no-fatal-infos
flutter test test/features/managed_isp test/lint/dead_file_test.dart
xcrun swiftc -typecheck -target "$(uname -m)-apple-macos15.0" macos/NetworkProtection/*.swift
swift_test="$(mktemp -d)/packet-policy"
xcrun swiftc macos/NetworkProtection/FilterPolicy.swift test/native/managed_filter/main.swift -o "$swift_test"
"$swift_test"
bash -n tool/package_managed_macos.sh
```

Flutter 测试默认触发 Go 和 Rust 构建钩子。只做这组 Dart 测试时，可在临时测试副本中把两个 `build_assets` 设为 `false`，测试后还原。
