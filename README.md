# MacStatus

轻量级 macOS 菜单栏状态监控工具（Apple Silicon 优先）。

![platform](https://img.shields.io/badge/macOS-13%2B-blue) ![arch](https://img.shields.io/badge/Apple_Silicon-arm64-orange)

## 功能

- **菜单栏实时显示**（4 种模式，可在面板中切换，偏好自动持久化）：
  - CPU 温度（如 `62°`）
  - 内存占用百分比
  - CPU 使用百分比
  - 纯图标模式（自定义折线模板图标，自动适配明暗菜单栏）
- **点击弹出监控面板**：
  - CPU 使用率 + 温度（彩色分级：≥70°C 橙色、≥85°C 红色）
  - 内存已用/总量 + 进度条
  - 风扇转速（M 系列空闲停转显示"停转"，不误报）
  - 传感器温度列表（带分类标签：CPU / GPU / 供电 / 电池 / 环境）
  - **内存占用 Top 5 应用**（按 .app 聚合 Helper 进程，口径与活动监视器一致）
- 无 Dock 图标，无需 root 权限

## 安装

从 [Releases](../../releases) 下载 `MacStatus.app.zip`，解压后拖到「应用程序」。

> **首次打开提示「Apple 无法验证」？** App 使用 ad-hoc 签名（未经公证），任选一种放行：
>
> ```bash
> xattr -cr /Applications/MacStatus.app
> ```
>
> 或：弹窗点「完成」→ 系统设置 → 隐私与安全性 → 底部点「仍要打开」。

## 从源码构建

无需 Xcode 工程，系统自带 Swift 工具链即可：

```bash
./build.sh
open build/MacStatus.app
```

依赖：macOS 13+ SDK、Apple Silicon（SMC 新旧协议自动探测，兼容 macOS 26/27 的新 SMC 接口）。

## 技术要点

- **SMC 读取**：IOKit AppleSMC 用户客户端。macOS 27 上 SMC 接口变更——所有命令统一走
  选择器 2、命令字节放 `data8`（5=读键 / 8=按索引枚举 / 9=查键信息）；旧系统仍用
  传统独立选择器，启动时自动探测协议。注意 Swift 不给 C 结构体补尾部对齐，
  `SMCParamStruct` 必须显式 padding 到 80 字节。
- **进程内存**：libproc（`proc_listallpids` + `proc_pidpath` + `proc_pid_rusage`），
  用 `phys_footprint` 聚合，避免 resident size 重复计数共享库。
- **菜单栏**：NSStatusItem + NSPopover（MenuBarExtra 在 macOS 26/27 有图标不渲染的 bug）。
- UI 用 SwiftUI，通过 NSHostingController 承载在 NSPopover 中。

## 目录结构

```
Sources/
  SMCKit.swift        # SMC 读写（新旧协议自适应）
  SystemStats.swift   # CPU/内存统计（host_statistics64 / host_page_size）
  Monitor.swift       # 采样模型：温度/风扇/内存/Top5 应用
  MacStatusApp.swift  # NSStatusItem + NSPopover + SwiftUI 面板
cli/                  # 开发调试工具（SMC 探针、内存单位验证）
Resources/            # Info.plist、菜单栏图标
build.sh              # 一键构建脚本
```

## License

MIT
