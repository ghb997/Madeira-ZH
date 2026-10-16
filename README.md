# Madeira 中文版

在 iPhone / iPad 上运行 Windows 游戏。基于 [willfaust/Madeira](https://github.com/willfaust/Madeira) 的独立简体中文版本，保留原作者、贡献者署名、许可证和上游 Git 历史。

[安装与 JIT 指南](docs/INSTALL-ZH.md) · [源码构建](docs/BUILDING-ZH.md) · [构建记录](https://github.com/ghb997/Madeira-ZH/actions) · [版本下载](https://github.com/ghb997/Madeira-ZH/releases) · [上游英文说明](README.upstream.md)

Madeira 是仍在开发的实验性项目。游戏兼容性、速度与稳定性因设备和游戏而异，汉化不会改变原项目的兼容性限制。

## 中文版范围

- 游戏库、搜索、分组、游戏详情、启动选项与设置。
- 首次使用引导、JIT 配对与诊断、权限说明。
- Steam 登录、游戏库、下载与安装、Steam 云存档冲突提示。
- Madeira Dock 启动状态、运行库安装、存档备份与快捷方式。
- 手柄、键盘、鼠标、触控按键与性能信息。
- 中文应用名称、系统权限提示与中文安装说明。

本分支直接维护简体中文界面，默认语言为 `zh-Hans`；Wine 默认区域为 `zh_CN.UTF-8`。配置键、协议字段、文件名、快捷指令名称与游戏标识保持原值，兼容原项目的数据格式。开发诊断日志、代码注释、许可证原文和第三方游戏本身不属于界面翻译；游戏是否有中文取决于其语言资源。

独立应用标识为 `com.ghb997.MadeiraZH`，JIT 助手为其 `.JITHelper` 扩展。侧载工具可能为两者追加团队标识。独立标识允许它与原版分别安装，但不会自动读取原版的应用沙盒；迁移前请备份游戏与存档。

## 下载与安装

1. 在本仓库的 [Releases](https://github.com/ghb997/Madeira-ZH/releases) 下载名称包含 `unsigned` 的 IPA。如果尚无发布版本，请查看 [Actions](https://github.com/ghb997/Madeira-ZH/actions) 中成功运行的构建产物。
2. 使用 SideStore、AltStore、Sideloadly、Plume 等工具，以自己的 Apple ID 重新签名并侧载。
3. 安装时保留 `MadeiraJITHelper` 扩展，内置 JIT 需要它。
4. 打开应用，按中文引导完成 LocalDevVPN、JIT 和可选 Steam 设置。
5. 检查 JIT 与内存权限状态，然后添加或下载游戏。

**IPA 不包含个人签名证书。** 未签名包需要侧载工具签名后才能安装，不能直接从浏览器点开安装。免费 Apple ID 的签名通常需要每 7 天刷新。详细步骤见 [安装与 JIT 指南](docs/INSTALL-ZH.md)。

当前上游建议使用 **iOS 26 或更高版本**。内置无电脑配对需要 iOS 27；iOS 26 可以导入电脑生成的配对文件，或使用 StikDebug。JIT 需要调试权限，因此本应用不通过 App Store 分发。

## 功能与原理

| 功能 | 说明 |
| --- | --- |
| 游戏库 | 封面、搜索、分类、单个游戏配置与 Windows 桌面会话 |
| Steam | 登录、浏览已拥有的游戏、下载、更新，并通过 Madeira Dock 启动 |
| 云存档 | 启动时与游戏开始前同步；退出时可上传；冲突需要选择，替换前保留备份 |
| 输入 | 蓝牙手柄、可定制触控按键、键盘、鼠标与触控板 |
| 音视频 | 使用 FFmpeg、VideoToolbox 和 AudioToolbox |
| 图形 | Direct3D 9 / 10 / 11 经 DXMT 转为 Metal，Direct3D 12 使用 madeira-d3d12 |

| 组件 | 作用 |
| --- | --- |
| [FEX-Emu](https://github.com/FEX-Emu/FEX) | 将 x86 / x86-64 指令动态翻译为 ARM64 |
| [Wine](https://www.winehq.org/) 11.4 | 提供 Windows API，ARM64EC 版本使 Wine 自身原生运行 |
| [DXMT](https://github.com/3Shain/DXMT) | 将 Direct3D 9、10、11 转换为 Metal |
| [madeira-d3d12](madeira-d3d12) | 基于 Metal 的 Direct3D 12 实现，使用 Apple Metal Shader Converter |

“完整汉化”指 Madeira 自身面向用户的界面。Steam、Windows 游戏与运行时下载内容属于第三方软件，其语言由自身决定。32 位游戏支持需要构建 WoW64；以对应构建说明与产物清单为准。

iOS 无法像桌面系统一样启动任意子程序，Madeira 因此在同一进程中运行游戏与多个运行时组件，Wine 服务端也以线程运行。

## 从源码构建

```sh
git clone --recurse-submodules https://github.com/ghb997/Madeira-ZH.git
cd Madeira-ZH
```

本项目不是只编译一个 SwiftUI 目标即可完成的普通 iOS 工程。FEX、Wine、DXMT、LLVM、FFmpeg、配对库和 Madeira Dock 都有原生依赖。GitHub Actions 使用 macOS/Xcode 构建并上传未签名 IPA，缓存可加速后续版本。

操作方法、依赖来源与排错见 [中文构建说明](docs/BUILDING-ZH.md)。上游记录保留在 [docs/BUILDING.md](docs/BUILDING.md)。只有实际成功的 Actions 运行才代表该提交已编译通过。

| 路径 | 内容 |
| --- | --- |
| `app/` | iOS 界面、Wine 桥接、JIT 助手与资源 |
| `FEX/`、`wine/`、`dxmt/`、`madeira-dock/` | 指向定制版本的 Git 子模块 |
| `madeira-d3d12/` | Direct3D 12 实现 |
| `build/` | 各运行时组件的构建脚本 |
| `.github/workflows/` | GitHub Actions 构建流程 |
| `tests/`、`tools/` | 检查与辅助脚本 |
| `docs/` | 安装、功能与构建文档 |

## 许可证与致谢

Madeira 使用 **GPL-3.0-or-later**，附带 **Madeira Converter Exception**。详见 [LICENSE](LICENSE)、[LICENSE-EXCEPTION.md](LICENSE-EXCEPTION.md)、[THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md) 与 [LICENSES](LICENSES)。本分支沿用这些许可，第三方许可文本保留原文。

Microsoft Visual C++ 运行库不包含在仓库或本分支的构建产物中。需要时请按 [tools/fetch-vcruntime.md](tools/fetch-vcruntime.md) 自行提供。Wine Mono 可由应用按需下载。

Madeira 由 **Will Faust（[@willfaust](https://github.com/willfaust)）**创建。感谢 Nick / 125hz、Jfishin、Jesse Lovelace、Dan Perks、bahacan16、spitefulowl、meshoklv、TheHadesc，以及 Wine、FEX-Emu、DXMT、rpmalloc、StikDebug、StikJIT、idevice 和其他依赖的贡献者。原始贡献说明见 [上游 README](README.upstream.md#credits)。

本仓库是社区中文衍生版本，不是原作者的官方中文发行。向其他上游贡献前请遵守各自的政策；原项目特别指出 FEX-Emu 不接受 AI 生成代码，请勿将本分支的相关改动直接提交到 FEX-Emu。
