<div align="center">

<img src="assets/images/icon.png" alt="FlClash" width="88">

# FlClash ISP

基于 [FlClash](https://github.com/chen08209/FlClash) 的 fork，新增 macOS 固定 ISP 分流。

[English](README.md) · **简体中文**

[![Release](https://img.shields.io/github/v/release/chen08209/FlClash?style=flat-square&label=release)](https://github.com/chen08209/FlClash/releases/latest)
[![Downloads](https://img.shields.io/github/downloads/chen08209/FlClash/total?style=flat-square&logo=github)](https://github.com/chen08209/FlClash/releases)
[![License](https://img.shields.io/github/license/chen08209/FlClash?style=flat-square)](LICENSE)
[![Telegram](https://img.shields.io/badge/Telegram-channel-26A5E4?style=flat-square&logo=telegram&logoColor=white)](https://t.me/FlClash)

[macOS 固定 ISP 指南](macos/NetworkProtection/README.md) · [同步上游](UPSTREAM_SYNC.md) · [上游版下载](#上游版下载) · [从源码构建](#从源码构建)

</div>

<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="snapshots/preview-dark.png">
    <img alt="FlClash 在 MacBook 与手机上的仪表盘" src="snapshots/preview.png" width="92%">
  </picture>
</p>

## macOS 固定 ISP

一个 Mihomo Core 同时运行 TUN 和固定 ISP 分流。普通应用按订阅规则走 VPN、直连或拒绝。由 FlClash ISP 打开的 Chrome 空间和命中的指定应用 TCP 连接走 VPN → SOCKS5 ISP。两条路径共用一个 VPN 节点选项。

1. 先退出原版 FlClash 并停止它的 TUN。打开 `FlClash ISP.app`，进入「配置 → 添加 → 配置 VPN 和固定 ISP」。
2. 粘贴 HTTPS 订阅和 `socks5://user:password@host:port` 连接串，可选填预期公网出口 IP。
3. 点「用固定 ISP 打开 Chrome」选择独立浏览空间，或进入「检查 macOS 和 Chrome → 指定应用」添加本机应用。按 macOS 提示完成 TUN 授权。

固定 ISP 链路确认故障后，Core 会分批寻找可经同一个 ISP 出口的 VPN 节点。全部失败时，固定 ISP 连接报错并进入冷却。普通应用继续按订阅分流，自动切换保留已建立的连接。「链路检查设置」里的定时检查默认关闭，开启后的默认间隔是 120 秒，可手动调整。

单 App 签名打包、诊断和验收见 [macOS 固定 ISP 指南](macos/NetworkProtection/README.md)。

## 功能

- **一个应用覆盖 Android、Windows、macOS 和 Linux**，桌面端同时提供 x64 与 ARM64 版本。
- **mihomo（Clash.Meta）内核**：规则分流、代理组、延迟测试、系统代理与 TUN 模式。
- **配置管理**：通过订阅链接或文件导入配置，内置编辑器，支持覆写脚本以及自定义规则、代理和代理组。
- **实时查看**连接、请求、DNS 查询和日志。
- **Material You 设计，融合 Apple 式交互**：支持动态取色、浅色与深色主题，连续曲率圆角，弹出面板可在几档高度间吸附，布局随屏幕从手机到桌面自适应。
- **备份与恢复**：通过 WebDAV 或本地文件。
- **平台细节**：Android 上有快捷设置磁贴、分应用代理和 Android TV 支持；桌面端有托盘菜单和全局快捷键。
- **开源无广告**，以 GPL-3.0 协议发布。

## 上游版下载

FlClash ISP 可按 [本机签名与打包](macos/NetworkProtection/README.md#本机签名与打包) 构建单 App。下列下载渠道提供原版 FlClash，包括上游的 [GitHub Releases](https://github.com/chen08209/FlClash/releases/latest) 和 [官网](https://chen08209.github.io/FlClash/zh#download)。

| 平台 | 安装包 | 说明 |
| --- | --- | --- |
| Android | `arm64`（arm64-v8a）、`armv7`（armeabi-v7a）、`amd64`（x86_64）三种 APK | 绝大多数手机选 `arm64`。也可以通过下方的 F-Droid 仓库安装。 |
| Windows 10 及以上 | 安装版（`.exe`）或便携版（`.zip`），分 x64 与 ARM64 | 骁龙等 ARM 架构笔记本选 ARM64。 |
| macOS 12 及以上 | Apple Silicon 与 Intel 两种 DMG | 也可以通过 Homebrew 安装。 |
| Linux | `.deb`、`.rpm` 和 AppImage，分 x64 与 ARM64 | 托盘依赖见下方说明。 |

<p>
  <a href="https://chen08209.github.io/FlClash-fdroid-repo/repo?fingerprint=789D6D32668712EF7672F9E58DEEB15FBD6DCEEC5AE7A4371EA72F2AAE8A12FD"><img alt="Get it on F-Droid" src="snapshots/get-it-on-fdroid.svg" height="56"></a>
  <a href="https://github.com/chen08209/FlClash/releases/latest"><img alt="Get it on GitHub" src="snapshots/get-it-on-github.svg" height="56"></a>
</p>

**Homebrew**

```bash
brew tap chen08209/tap
brew install --cask flclash
```

**Linux 托盘图标**

托盘图标是 StatusNotifierItem。KDE Plasma、XFCE 和多数面板直接显示；GNOME 需要安装 AppIndicator and KStatusNotifierItem Support 扩展。

**无人值守的桌面环境**

Windows 和 Linux 上，FlClash 在免责声明被接受后启动核心。在容器等无人值守环境里，可在应用的环境变量中设置
`FLCLASH_ACCEPT_DISCLAIMER=1`。

## 使用

**通过链接导入配置。** 打开下面格式的链接，即可把订阅导入 FlClash。`clashmeta://` 和 `flclash://` 开头的链接同样可用。

```text
clash://install-config?url=<经过 URL 编码的订阅链接>
```

**Android 自动化。** Tasker、MacroDroid 等应用可以用下面的 Action 启动 Activity，从而启动、停止或切换代理：

```text
com.follow.clash.action.START
com.follow.clash.action.STOP
com.follow.clash.action.TOGGLE
```

在电脑上也可以通过 adb 触发：

```bash
adb shell am start -a com.follow.clash.action.TOGGLE
```

## 从源码构建

需要 [Flutter](https://docs.flutter.dev/get-started/install) 3.50（正式版构建使用 3.50.0）、[Go](https://go.dev/dl/) 1.27，
以及通过 rustup 安装的 [Rust](https://rustup.rs/)。桌面端需要在对应系统上构建，Android 在任意系统上都能构建。

```bash
git clone https://github.com/milesradford99/FlClash.git
cd FlClash
git -c url.https://github.com/.insteadOf=git@github.com: submodule update --init --recursive
flutter pub get
dart run tool/package.dart android   # 或 windows、macos、linux
```

安装包输出到 `dist/`。Go 内核和 Rust 库会在 Flutter 构建过程中一并编译。

| 平台 | 额外依赖 |
| --- | --- |
| Android | 带 NDK 的 Android SDK。加上 `--arch arm64` 可以只构建单个 ABI。 |
| Windows | 编译内核用的 GCC（MinGW-w64），以及打包安装程序用的 [Inno Setup](https://jrsoftware.org/isinfo.php) 6。 |
| macOS | Xcode 与 Node.js。脚本会通过 npm 安装 `appdmg`。 |
| Linux | Debian 或 Ubuntu。脚本会用 apt 安装构建所需的软件包，并下载 `appimagetool`。 |

其余选项可以运行 `dart run tool/package.dart --help` 查看，例如用 `--targets` 只构建部分安装包格式，用 `--dry-run` 列出这次会生成的文件。

## 支持

固定 ISP 的改动见 [本项目 PR](https://github.com/milesradford99/FlClash/pulls)，维护流程见 [同步上游指南](UPSTREAM_SYNC.md)。
原版 FlClash 的通知、问题反馈与更新记录见上游的 [Telegram 频道](https://t.me/FlClash)、[GitHub Issues](https://github.com/chen08209/FlClash/issues) 和 [更新日志](CHANGELOG.md)。

<a href="https://star-history.com/#chen08209/FlClash&Date">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="https://api.star-history.com/svg?repos=chen08209/FlClash&type=Date&theme=dark">
    <img alt="Star history" src="https://api.star-history.com/svg?repos=chen08209/FlClash&type=Date" width="640">
  </picture>
</a>

## 许可证

FlClash 以 [GPL-3.0 协议](LICENSE)发布。
