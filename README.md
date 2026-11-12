# DualChatGPT

DualChatGPT 是一个 Vue 3 + Tauri 2 桌面启动器。原窗口继续使用官方客户端原有数据，第二窗口使用独立的本地目录；账号登录在官方客户端完成。界面提供窗口状态、第二窗口启动、客户端路径设置和使用指南。

## 平台状态

- **Windows：**用户于 2026 年 11 月 12 日确认两个账号可以同时使用。图形版复用此前的 PowerShell 启动与目录检查，保留 `%LOCALAPPDATA%\DualChatGPT\profiles` 下的第二窗口数据。
- **macOS：**已加入基于客户端签名、目录开关和进程检查的独立适配，使用 `~/Library/Application Support/DualChatGPT/profiles`；尚待在 Mac 上编译与双账号实机验证。客户端版本、签名或内部开关不符合检查时会显示原因。
- 聊天记录隔离、关闭一个窗口后的状态、重启后历史、长期令牌刷新和客户端升级后的行为尚未逐项记录。不同目录的进程本身不代表完整隔离。

## 使用

1. 正常打开官方客户端，确认原有项目和聊天可见。
2. 打开 DualChatGPT，选择“打开第二窗口”。首次启动会创建第二窗口的数据目录，不复制原窗口的登录信息。
3. 在官方登录界面选择另一个账号，分别核对两个窗口显示的账号和聊天列表。
4. 界面自动刷新进程状态，也可以手动刷新。Windows 中可以点击“关闭窗口”正常关闭第二窗口；若客户端仍在后台，再点“打开第二窗口”即可重新显示。关闭窗口不会主动退出账号或强制结束后台进程。自动查找失败时，可在设置中输入客户端完整路径：Windows 为程序文件，macOS 为 `.app` 目录。

若显示未识别进程或启动失败，请先保存工作并检查窗口；程序不会自动关闭客户端、注销账号或清理数据。账号数据和验证报告请留在本机，不要提交到仓库。

## 本地开发与构建

需要 Node.js、Rust 和各平台的 Tauri 构建依赖：Windows 需要 Microsoft C++ Build Tools、Windows SDK 和 WebView2；macOS 需要 Xcode Command Line Tools。详情参见 [Tauri 环境要求](https://v2.tauri.app/start/prerequisites/)。

```sh
npm ci
npm run test
npm run tauri dev
npm run tauri build
```

Tauri 应用和安装包需在对应的目标系统构建；正式分发还需配置各平台的签名和 macOS 公证。构建输出位于 `src-tauri/target/release/`。2026 年 11 月 12 日已在本机编译并测试 Windows x64 安装包：安装后界面能够识别原窗口和第二窗口的进程，并通过界面启动第二窗口。该构建未配置代码签名；macOS 图形版和双账号行为仍待实机验收。

本机还配置了一份独立于系统环境变量的构建环境，位于 `%LOCALAPPDATA%\DualChatGPT-build`。当前项目可在 PowerShell 中运行 `& "$env:LOCALAPPDATA\DualChatGPT-build\build.ps1"` 重新构建 Windows 安装包；此脚本使用本机现有 MSVC、用户目录中的 Rust 和 Windows SDK，路径针对当前机器配置。

Windows 命令行入口 `启动第二窗口.cmd` 与 `检查运行状态.cmd` 仍可使用。`probe/` 保留原实机验证工具，它使用全新 A/B 测试目录，适合排查，不应把它的全新 A 当作原窗口。

## 测试

`npm run test` 检查界面状态、启动交互和路径设置；`npm run build` 检查前端类型与生产构建。Windows 还可运行 `powershell -NoProfile -File tests\Test-Launcher.ps1`、`powershell -NoProfile -File probe\Test-Probe.ps1` 和 `powershell -NoProfile -File probe\Test-Diagnostics.ps1`。本机配置的 `test.ps1` 还会运行 Rust 回归测试。这些自动测试不代替各平台实机验收。
