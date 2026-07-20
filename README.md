# Codex Pet Quota Overlay

这是一个 macOS 菜单栏后台小工具，把当前 Codex 账户的 5 小时额度、周额度和重置倒计时显示在 Codex 桌宠旁。当前版本已经完成原生面板、桌宠跟随、额度读取、断线恢复和本地打包；release 脚本会构建同时支持 Apple Silicon（arm64）与 Intel（x86_64）的通用应用。应用尚未签名或公证。

## 界面示意

![Codex Pet 额度面板实际效果](docs/images/codex-pet-quota-overlay.png)

> 实际运行效果：额度面板以紧凑悬浮窗显示剩余额度和重置倒计时，可拖动调整相对桌宠的位置。

紧凑面板固定为两行，低额度会变为橙色或红色：

```text
┌──────────────────────┐
│ ⏱ 5h  82% · 2小时14分 │
│ 📅 周  61% · 4天8小时  │
└──────────────────────┘  [桌宠]
```

## 使用要求

- macOS 13 或更高版本
- 已安装 `codex` 命令，并已登录 Codex
- 从源码构建需要 Xcode Command Line Tools / Swift 6

## 从 GitHub Release 快速安装

1. 打开 [Releases](https://github.com/chenxinran807-bot/codex-pet-usage-visibility/releases)，下载最新版 `Codex-Pet-Quota-v*.zip`。
2. 解压后双击 `安装.command`。它会把应用安装到 `~/Applications`，安装随附桌宠，启动额度面板，并设置为登录时打开。
3. 在 Codex 桌宠设置中选择“像素代码伙伴”。

当前应用未签名或公证。首次打开若被 macOS 阻止，请打开“系统设置 → 隐私与安全性”，在安全提示旁点击“仍要打开”，然后再次双击应用或安装脚本。只从本仓库的 GitHub Release 下载，并可在 Release 页面核对 SHA-256。

如果 macOS 拒绝自动设置登录项，安装不会中断，额度面板仍会启动。请按脚本提示前往“系统设置 → 通用 → 登录项”手动添加；安装器不会覆盖同名但指向其他应用的登录项。

卸载时双击压缩包内的 `卸载.command` 并确认。脚本只删除经过 bundle identifier 和桌宠 id 校验的项目文件；安装时创建的备份会保留。

## 从源码构建、安装与启动

```bash
scripts/build-release.sh
scripts/install.sh
open "$HOME/Applications/Codex Pet Quota.app"
```

默认安装到 `~/Applications`。也可运行 `scripts/install.sh --target "/自定义目录"`；先用 `--dry-run` 查看动作。安装脚本还会把随附桌宠复制到 `${CODEX_HOME:-$HOME/.codex}/pets/pixel-code-companion`。若目标中已存在同名应用或同名桌宠，会先留下带时间戳的备份，其他桌宠不会被修改。

首次打开若被 Gatekeeper 阻止，请在“系统设置 → 隐私与安全性”确认来源后选择仍要打开。正式分发应另行签名和公证。

### 登录时启动（源码安装）

打开“系统设置 → 通用 → 登录项”，点击“登录时打开”下方的 `+`，选择 `~/Applications/Codex Pet Quota.app`。本项目不会擅自修改登录项。

### 选择桌宠

在 Codex 的桌宠设置中选择“像素代码伙伴”。面板会跟随检测到的桌宠窗口移动。

可直接拖动整块额度面板来调整它相对桌宠的位置。拖动结束后，面板仍会按新的相对位置跟随桌宠；该位置保存在本机偏好设置中，退出应用或重启电脑后仍会恢复。双击面板可清除自定义位置并恢复默认贴边位置。

## 数据来源与隐私

额度来自本机 `codex app-server` 的实验性 `account/rateLimits/read` 与更新通知，不是稳定公开 API，Codex 升级可能改变协议。本应用不内置、读取或保存密码、令牌、Cookie，也不保存原始账户响应；进程错误不会打印服务端原始账户数据。网络异常、未登录、Codex 停止或协议错误时会显示“额度暂不可用”或保留带过期标记的最后一次结果，不会编造额度窗口。

## 卸载

```bash
scripts/uninstall.sh
# 无交互：scripts/uninstall.sh --yes
# 预览：scripts/uninstall.sh --yes --dry-run
```

卸载只删除 `~/Applications/Codex Pet Quota.app` 和当前 `CODEX_HOME` 下的 `pets/pixel-code-companion`。删除前会核对应用 bundle identifier 与桌宠 id，并拒绝符号链接、异常目录或同名但不属于本项目的内容。安装时产生的备份会保留，其他应用和桌宠不受影响。自定义安装目录需同时传 `--target`。

## 故障排查

### “额度暂不可用”

确认 Codex 已登录，并在终端运行 `codex --version`。退出后重新登录 Codex，再重启本应用；网络恢复后可点击面板手动刷新。

### 检测不到桌宠

确认桌宠目录中同时存在 `pet.json` 和 `spritesheet.webp`，然后在 Codex 中重新选择桌宠。桌宠重新被识别后，面板会继续使用已保存的相对位置跟随；双击面板可恢复默认贴边位置。

### App Server 协议变化

升级 Codex 后若持续不可用，请运行默认测试并记录 Codex 版本、macOS 版本和错误类别后提交问题。不要附加账户响应、令牌、Cookie 或完整环境变量。

### 日志与敏感信息

可从“控制台”应用按进程名 `QuotaOverlayApp` 筛选本地日志。分享日志前再次检查并移除用户名、主目录路径和任何凭证；应用设计上不会记录原始额度载荷或密钥。

## 开发与验证

```bash
CLANG_MODULE_CACHE_PATH="$PWD/.build/module-cache" \
SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/module-cache" swift test --disable-sandbox

scripts/build-release.sh
bash -n scripts/build-release.sh scripts/install.sh scripts/uninstall.sh scripts/package-release.sh
scripts/test-installation.sh
scripts/test-login-item.sh
scripts/test-package-release.sh
plutil -lint "dist/Codex Pet Quota.app/Contents/Info.plist"
lipo -archs "dist/Codex Pet Quota.app/Contents/MacOS/QuotaOverlayApp"
```

生成供 GitHub Release 使用的安装包：

```bash
scripts/build-release.sh
scripts/package-release.sh 0.1.0
shasum -a 256 dist/Codex-Pet-Quota-v0.1.0.zip
```

默认测试绝不会启动真实 Codex。只有在测试机已登录、明确同意使用真实账户时才运行：

```bash
RUN_LIVE_CODEX_TESTS=1 CLANG_MODULE_CACHE_PATH="$PWD/.build/module-cache" \
SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/module-cache" \
swift test --disable-sandbox --filter LiveAppServerTests
```

该测试有超时和清理机制，只断言响应可解码且显示窗口可追溯到服务端数据，不输出额度或账户原始内容。

本项目采用 [MIT License](LICENSE)。
