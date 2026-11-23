# 固定 ISP 模式开发与验收

## 当前可验证范围

开发分支包含 [两种 profile 共用的输入和 ISP 路由生成器](../../lib/features/managed_isp/profile.dart)，以及一个独立的 [macOS 数据包过滤探针](PacketFilterProvider.swift)。两者目前均未接入 FlClash 的运行入口。常规构建仍是上游的 profile 使用流程。该分支没有可启用的严格保护模式，也没有可安装的测试扩展。

- 生成器接受 HTTPS 订阅 URL 和 SOCKS5 主机、端口、用户名、密码。纯 VPN 使用原始订阅。固定 ISP 的路由片段为每个支持的独立上游节点生成一条 SOCKS5 链路。业务匹配只指向这些链路的故障转移组。订阅源须提供内联 `proxies`。已有上游拨号链和仅由 `proxy-providers` 提供节点的订阅需要另行适配。生成器还不负责订阅的下载、保存、调度刷新或处理系统授权。
- 探针测试系统是否把出站数据包交给过滤扩展。它允许入站及回环，丢弃框架交给它的其他出站包。它会让测试机断网，包括可能会干扰 DHCP 续租。它没有 VPN 拨号例外，也不代表产品的最终策略。
- 当前构建仅进行了 Dart 测试和 Swift 编译检查。系统扩展尚未签名、注册或运行。开机、换网和扩展异常时的覆盖需要在独立测试机上测量。

## 本地源码检查

使用仓库锁定的 Flutter 版本和子模块。以下命令不会启动 FlClash 或安装系统网络组件。

```sh
git submodule update --init --recursive
flutter pub get
flutter analyze --no-fatal-infos
flutter test test/features/managed_isp test/lint/dead_file_test.dart
xcrun swiftc -typecheck macos/NetworkProtectionProbe/PacketFilterProvider.swift
```

测试使用虚构订阅、节点和 ISP 鉴权信息。仓库的 Flutter 测试默认运行 Go 和 Rust 原生资源构建钩子。只做这组 Dart 测试时，可在临时测试副本中将 `pubspec.yaml` 的两个 `build_assets` 改为 `false`。保留交付分支上的原始值。

## 独立 Mac 上验证过滤能力

准备可从本地控制台操作的测试 Mac、完整 Xcode、支持 Network Extension 系统扩展的签名配置，以及一台能从测试机外部记录流量的设备或网关。覆盖 Intel macOS 15 时使用对应架构的测试机。安装前先确认可以从本地控制台停用过滤器，并把测试机的网络恢复方式记在另一台设备上。全程使用测试订阅、测试 ISP 和中立测试端点。

1. 另建测试 App 或用 Apple 的 [Filtering Network Traffic 示例](https://developer.apple.com/documentation/networkextension/filtering-network-traffic) 作为宿主。把探针加入该宿主的 **macOS Network Extension 系统扩展** target。在扩展 `Info.plist` 的 `NetworkExtension → NEProviderClasses` 中为 `com.apple.networkextension.filter-packet` 注册探针类。使用独立于 FlClash 的 App 和扩展 bundle ID，按 Apple 的说明配置宿主及扩展签名。
2. 在测试宿主的 `NEFilterProviderConfiguration` 里设置 `filterPackets = true`、`filterSockets = false`，并指定 `filterPacketProviderBundleIdentifier` 为探针扩展的 bundle ID。按系统流程激活扩展并启用过滤器。仅在这台独立 Mac 上完成确认。
3. 启用前记录 IPv4、IPv6、DNS 和 UDP 的可用基线。从外部设备持续记录测试 Mac 到受控目的地的流量。启用探针后，检查新建连接和原有的长连接均不再向测试目的地发送数据。记录授权、启用、退出宿主、注销、重启、换网和唤醒的时间点。每个场景继续保留测试流量及外部抓包证据。
4. 从测试机本地控制台停止测试宿主的网络过滤。如果宿主不可用，在系统设置中找到其网络过滤器并停用。恢复网络后检查同一组基线。测试结束后清理测试扩展。

无基线流量、没有覆盖 IPv6 的测试网络，或冷启动期间没有有效采样时，相应结果记为未验证。

参考 [Apple 扩展部署说明](https://developer.apple.com/documentation/technotes/tn3134-network-extension-provider-deployment) 和 [流量过滤 API](https://developer.apple.com/documentation/networkextension/content-filter-providers)。

## 完整版联调验收

下面的用例适用于接入向导、订阅更新、系统保护和运行状态后的构建。现有探针仅用于验证 macOS 过滤能力。

| 场景 | 预期结果 |
| --- | --- |
| 同一订阅初始化两份 profile | 纯 VPN 保留原分流，01 使用同一订阅生成到同一固定 ISP 的链路 |
| 刷新订阅并重启 | 新增、改名和删除的节点跟随订阅变化。无效刷新保留最后一份通过验证的配置 |
| 当前 VPN 节点失败 | 有可用候选时恢复到同一个固定 ISP。现有连接和新连接都不能绕过 ISP |
| 全部 VPN 节点不可达，或 SOCKS5 拒绝认证 | 应用显示阻断。新旧业务连接均不会自动切换到纯 VPN 或系统直连 |
| 强退界面、终止内核、系统扩展停止或重启 | 在外部网关验证保护仍生效。存在任何未经授权的业务包即为失败 |
| 冷启动未登录、唤醒以及 Wi‑Fi 和有线切换 | 连续采集物理出口流量，检查从连接建立到系统保护就绪的整个窗口 |
| 用户主动切换至纯 VPN | 完成切换后才按原订阅分流。01 退出前的连接状态不能沿用到纯 VPN |

完整版还需把拨号、DHCP 等必要流量例外写成明确的策略。订阅下载和业务 DNS 不能靠添加普通直连来恢复。应用必须拿到系统层的保护确认后才允许启用 01。Chrome WebRTC 检测和系统偏好检查属于后续集成。
