# 构建简体中文版 IPA

本仓库会使用 Xcode 重新编译汉化后的 Swift、Objective-C 和 C/C++ 源码，
并将未签名应用打包为 IPA。构建不需要 Apple 开发者证书，下载后须自行侧载签名。
Windows 本机不能运行 Xcode；GitHub Actions 使用 macOS 15 托管构建机。

## 在 GitHub 上构建

1. 打开仓库的 **Actions → 构建 Madeira 简体中文 IPA → Run workflow**。
2. 默认启用完整 32 位 WoW64 运行时。首次构建会编译 Wine、FEX、LLVM、DXMT、
   FFmpeg 和 Rust 配对库，可能耗时数小时；GitHub 单次作业上限为 6 小时。
3. 成功后下载 `Madeira-ZH-构建编号-unsigned-ipa`，解压取得 `.ipa`、SHA-256 校验和和构建清单。
4. 使用侧载工具重新签名安装，并按上游 [JIT 说明](JIT.md) 启用 JIT。

工作流仅手动触发，提交代码不会自动启动昂贵的 macOS 全量构建。
各原生库完成后立即保存缓存，因此应用编译失败不会丢失已完成的库。
修改 UI 文案通常可以复用原生库缓存。

取消 WoW64 选项仅供先验证 64 位构建链，生成的 IPA 不包含完整的 32 位 Windows
运行时；构建清单会明确记录 `wow64_built: false`。正式分发请保留默认选项。

## 来源和版本

- Wine、FEX、DXMT、Madeira Dock：仓库记录的 Git 子模块提交，递归获取。
- LLVM：`8dfdcc7b7bf66834a761bd8de445840ef68e4d1a`，与上游构建记录一致。
- Freetype：2.13.3，提交 `42608f77f20749dd6ddc9e0536788eaad70ea4b5`。
- llvm-mingw：20260421 macOS universal；下载后校验上游记录的 SHA-256。
- GMP、Nettle、GnuTLS、FFmpeg：仓库携带的源代码包及校验和。
- Rust：`build/rppairing-ios/Cargo.lock` 锁定的依赖。
- Metal Shader Converter：使用上游已提交的公共头文件及 iOS 动态库，构建时验证哈希。
  不要求下载 Apple 私有安装包。
- Microsoft VC++ 运行库：不随自动构建分发。需要 MSVC 运行库的游戏须自行提供合法获得的
  原版 DLL，参见 [fetch-vcruntime.md](../tools/fetch-vcruntime.md)。
- 上游已提交的 Windows ARM64EC / aarch64 DLL、StikJIT framework 和前缀模板保持原样。
  这是一份从源码重编译应用与原生库的构建，不是对所有第三方二进制逐一重建。

`tools/build-native-ci.py` 仅处理全新 Wine 配置的头文件扫描，以及 Apple 平台禁用
rpmalloc 时的诊断函数。Wine 只在扫描缺失的 ARM64EC 生成文件时使用占位内容；
本工作流保留已提交的 ARM64EC ntdll，不使用该占位文件编译 ARM64EC ntdll。

工作流沿用上游要求的 **Debug** 应用配置，因为上游记录 Release 配置曾导致客户程序崩溃。
“未签名”表示没有 Apple 开发者身份签名及配置描述文件。打包时使用无需证书的
ad-hoc 临时签名保存上游的 JIT、调试和内存权限声明，并验证嵌入组件与应用的封装。
这种临时签名不能直接用于普通设备安装；侧载工具仍须用你的身份重新签名应用、
JIT 助手和嵌入式组件，并保留所需的权限。

## 本地 macOS 构建

准备 Xcode 26 或更高版本、Homebrew 的 `bison llvm lld ninja meson`，
以及 Rust/rustup；将新版 bison、LLVM 和 lld 加入 PATH。然后运行：

```bash
git submodule update --init --recursive
export BUILD_WOW64=true
bash tools/build-native-ci.sh all
```

输出位于 `build-out/`。可按 `prepare`、`wine`、`fex`、`llvm`、`dxmt`、`pairing`、
`runtime`、`archive` 顺序单独运行阶段。失败时查看 `build-out/logs/` 和 Actions 日志附件。

上游清洁环境构建记录仍包含未验证步骤，尤其是 macOS WoW64 构建。
只有当前提交的 Actions 作业成功并实际产生 IPA，才可视为该提交完成了云端编译验证；
编译成功不等于已经完成真机游戏兼容性测试。

构建修复参考了公开的 [madeira-bcd 构建流程](https://github.com/Aettarrass-sys/madeira-bcd/blob/main/.github/workflows/build-ipa.yml)，
并根据本仓库更新后的依赖布局重新实现。上游完整说明见 [BUILDING.md](BUILDING.md)。
