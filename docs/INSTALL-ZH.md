# Madeira 中文版安装与 JIT 指南

## 安装前

- 使用 iOS 26 或更新系统。游戏表现取决于设备内存、芯片和游戏本身。
- 准备 Apple ID 与侧载工具，如 SideStore、AltStore、Sideloadly 或 Plume。
- 下载本仓库生成的未签名 IPA，交给侧载工具重新签名。
- 保留 `MadeiraJITHelper` 扩展，并使用支持调试的开发签名。
- 从原版迁移前备份游戏和存档。本分支标识不同，数据不会自动迁移。

IPA 中的临时签名仅用于携带 JIT、调试和内存权限声明，不是可直接安装的 Apple
开发者签名。侧载时让工具重新签名应用及全部嵌入组件；若工具提供权限设置，保留
`get-task-allow` 与应用请求的内存权限。

首次启动会介绍 JIT、Steam、Madeira Dock 与 Wine Mono，可选步骤可以稍后在设置中补做。

## 启用 JIT

JIT 将游戏指令翻译为 ARM64 代码。iOS 要求调试器参与创建可执行内存，因此只安装 IPA 并不足以运行游戏。

“自动”方式在检测到 StikDebug 时使用它，否则使用内置 StikJIT。失败后不会悄悄切换方式，请根据提示修复配对、VPN 或开发者磁盘映像。

### StikDebug

1. 安装 [StikDebug](https://github.com/StikDebug/StikDebug/releases/latest)。
2. 按 [配对文件指南](https://github.com/StikDebug/StikDebug-Guide/blob/main/pairing_file.md) 为这台 iPhone 生成配对文件，导入 StikDebug。
3. 安装并连接 [LocalDevVPN](https://apps.apple.com/us/app/localdevvpn/id6755608044)。
4. 返回 Madeira，轻点“启用 JIT”，按提示完成跳转。

请从 Madeira 发起启用操作。在 StikDebug 应用列表中单独启用，有可能在 Madeira 建立 JIT 内存池前就断开调试器。

### 内置 JIT 与电脑生成的配对文件

适用于 iOS 26 及更高版本的普通侧载安装，不适用于模拟器或 LiveContainer。

1. 为当前 iPhone 生成配对文件。
2. 在引导中选择带配对文件的内置方式，或进入“设置 › JIT › JIT 设置”导入文件。
3. 安装并连接 LocalDevVPN。
4. 轻点“检查设置”，按需下载、挂载匹配的开发者磁盘映像。
5. 轻点“启用 JIT”。

配对文件是此 iPhone 的凭证。Madeira 将其保存在本机钥匙串，不会放到 Windows 游戏可读取的 Documents 目录。Steam 登录凭证也保存在钥匙串。

### 应用内配对（iOS 27 及更高版本）

1. 打开 Wi-Fi，在 Madeira 引导或 JIT 设置中开始配对，并允许本地网络权限。
2. 打开 iOS“设置 › 隐私与安全性 › 开发者模式”，找到与 Madeira 配对的选项。
3. 输入 Madeira 显示的验证码，后台任务横幅或通知也可能显示该验证码。
4. 回到 Madeira，连接 LocalDevVPN、检查设置并启用 JIT。

新配对会替换之前的记录，只使用最新配对文件。如果系统不允许持续后台处理，请开始后立即切换到设置完成操作。超过五分钟会停止配对。

## LocalDevVPN 与快捷指令

两种方式都通过 LocalDevVPN 的 `10.7.0.1:62078` 回环连接访问本机。蜂窝数据、其他 VPN 或未建立的隧道可能导致连接失败。

iOS 27 可以安装名为 **Madeira JIT** 的快捷指令，并在 JIT 设置中启用。名称是调用协议的一部分，请不要改名。快捷指令会按需切换蜂窝数据与 VPN，并在处理结束后恢复。首次使用请阅读并允许“快捷指令”应用的权限请求。

没有安装快捷指令时，保持对应开关关闭。网络不可用时，可通过本地副本分享入口，将随包提供的快捷指令添加到“快捷指令”应用。

## 开始游戏

1. 检查 JIT 和内存权限状态。
2. 在游戏库添加 Windows 可执行程序，或登录 Steam 下载自己拥有的游戏。
3. 根据需要调整分辨率、触控方案和游戏兼容性选项。
4. 轻点“开始游戏”；若 JIT 尚未开启，应用会先尝试启用。
5. 使用 Steam 云存档时，退出前选择上传存档并关闭应用；出现冲突时确认要保留的版本。

原项目通常在每次应用运行中只启动一个 Wine 会话。提示重启时，从应用切换器彻底关闭 Madeira 后再打开。

## 常见问题

| 现象 | 处理方法 |
| --- | --- |
| 缺少 JIT 助手 | 重新侧载并保留扩展，或改用 StikDebug |
| 不允许调试 | 使用保留 `get-task-allow` 的开发签名重新安装 |
| 无法连接 / early eof | 检查 LocalDevVPN、其他 VPN 冲突与蜂窝数据，回到 Wi-Fi 后重试 |
| 更新 iOS 后磁盘映像失效 | 在 JIT 设置中重置开发者磁盘映像，再检查设置 |
| 配对被拒绝 | 为当前设备重新配对或导入最新配对文件 |
| 缺少 .NET Framework | 在设置中下载 Wine Mono，不是所有 .NET 应用都兼容 |
| 缺少 Visual C++ 运行库 | 按游戏需求自行安装官方运行库，本项目不附带微软 DLL |
| 中文游戏显示方框 | 游戏或 Wine 可能缺少中文字体，界面汉化不会附带第三方字体 |
| 32 位游戏无法启动 | 确认构建包含 WoW64 与 i386 运行库，再检查兼容性 |
| 免费签名到期 | 使用原侧载工具刷新，避免卸载造成数据丢失 |

更多协议、后台行为与快捷指令实现说明见 [上游 JIT 文档](JIT.md)。
