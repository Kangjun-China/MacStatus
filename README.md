# MacStatus

macOS 菜单栏系统状态监控：CPU 温度 / 风扇转速 / 内存 / CPU 占用率 / 传感器温度 / 内存占用 Top 5 应用。

纯 Swift 实现，无第三方依赖，无需 root 权限。

![platform](https://img.shields.io/badge/macOS-13%2B%20Apple%20Silicon-blue) ![lang](https://img.shields.io/badge/Swift-6-orange)

## 功能

- **菜单栏显示模式**（面板底部切换，偏好持久化）：
  - CPU 温度（如 `62°`）
  - 内存占用百分比
  - CPU 使用百分比
  - 仅图标（自定义模板图标，明暗菜单栏自动适配）
- **监控面板**：
  - CPU 使用率 + 温度（≥70°C 橙色、≥85°C 红色分级）
  - 内存已用 / 总量 + 进度条
  - 风扇个数与转速（Apple Silicon 空闲停转会标注"停转"，不会误报为未检测到）
  - 传感器温度 Top 6（带分类标签：CPU / GPU / 供电 / 电池 / 环境）
  - 内存占用 Top 5 应用（按 .app 聚合 Helper 进程，`phys_footprint` 口径，与活动监视器一致）
- 点击面板外自动关闭；面板底部一键退出

## 安装

从 [Releases](../../releases) 下载 `MacStatus.app.zip`，解压后拖入「应用程序」。

首次打开若提示「Apple 无法验证」（ad-hoc 签名 + 隔离标记），任选其一放行：

```bash
# 方式一：终端一步到位
xattr -cr /Applications/MacStatus.app
```

```
# 方式二：图形界面
# 警告弹窗点「完成」→ 系统设置 → 隐私与安全性 → 点「仍要打开」
```

## 构建

```bash
./build.sh   # 产物在 build/MacStatus.app
```

无 Xcode 工程，直接 swiftc 编译；命令行验证工具：

```bash
xcrun swiftc -O Sources/SMCKit.swift Sources/SystemStats.swift cli/main.swift -o smctest
./smctest   # 打印 SMC 键数量、温度键、风扇、CPU/内存统计
```

## 技术要点（踩坑记录）

- **macOS 26/27 SMC 协议变更**：旧的用户客户端选择器（读键=5/查信息=9 直接调用）全部返回
  `kIOReturnUnsupported`。新协议统一走 **选择器 2 + data8 命令字节**（5=读键、8=按索引枚举键名、
  9=查键信息），`open` 用 type 0。本仓库的 `SMCKit` 会先探测新协议，失败自动回退旧协议，
  兼容 macOS 13–27。
- **`SMCParamStruct` 必须是 80 字节**：Swift 不会给嵌套结构体补尾部对齐，
  `SMCKeyInfoData` 会被布局成 9 字节（C 是 12），导致整体 76 字节、IO 调用静默失败。
  需要显式加 padding 并用 `assert` 兜底。
- **MenuBarExtra 图片 label 在 macOS 26/27 不渲染**（`Image(systemName:)` / `Image(nsImage:)` /
  `Text(Image(...))` 全部空白），纯文字正常。因此本 App 用 **NSStatusItem + NSPopover** 实现
  菜单栏，面板用 NSHostingController 承载 SwiftUI，并设置
  `sizingOptions = .preferredContentSize` 让弹窗高度自适应（否则顶部会被截断）。
- **`proc_pid_rusage` 的 Swift 导入签名是 `void**`**：传结构体地址的常规 C 写法在 Swift 里
  会把 464 字节的 rusage 结构写进 8 字节指针变量，踩内存。正确做法是
  `withUnsafeMutableBytes` 把缓冲区首地址作为 `rusage_info_t` 传入。
- 部署目标用 `-target arm64-apple-macos13.0` 显式指定；否则 swiftc 默认取 SDK 版本
  （27.0），旧系统直接拒绝加载。
- CPU 温度取 `Tp*` 前缀键最大值（Apple Silicon 性能核心结温）；风扇个数 `FNum`、
  转速 `F{n}Ac`（fpe2 /4）。

## 目录结构

```
Sources/
  SMCKit.swift        # SMC 读取（新协议探测 + 旧协议回退）
  SystemStats.swift   # CPU 使用率（host_processor）、内存（host_statistics64）
  Monitor.swift       # 采样模型：温度/风扇/内存/Top5 应用（libproc）
  MacStatusApp.swift  # NSStatusItem + NSPopover + SwiftUI 面板
cli/                  # 命令行验证与协议探针工具
Resources/            # Info.plist、菜单栏图标
build.sh              # 一键构建脚本
```

## License

MIT
