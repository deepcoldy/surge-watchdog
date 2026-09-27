# 开发与构建

[返回项目首页](../README.md)

日常使用推荐 [已签名的发行版](https://github.com/deepcoldy/surge-watchdog/releases/latest)。本页面向需要修改源码、自行构建或维护发布流程的开发者。

## 从源码安装

需要 Apple Silicon Mac 和 Apple Command Line Tools。

```sh
git clone https://github.com/deepcoldy/surge-watchdog.git
cd surge-watchdog
./scripts/test.sh
./scripts/install.sh
```

测试使用临时目录和模拟数据，覆盖首次安装、更新和失败回滚，不安装到真实用户目录，也不对真实 Surge 执行恢复操作。

安装器会构建 App，安装后台检查器和两个 LaunchAgent，保留已有配置并补充新增默认项。改变健康检查 LaunchAgent 前，会运行只读健康检查；如果当前 Surge 不健康，则拒绝继续该步骤。

与发行版的图形安装流程不同，源码安装可能直接启用监控。手动测试 Surge 故障前，请确认监控开关符合预期。

未设置 Developer ID 身份时使用本机 ad-hoc 签名，仅适合开发。安装脚本拒绝用 ad-hoc 构建覆盖已经正式签名的 App。

如果 Command Line Tools 更新后 Swift 与默认 SDK 不匹配，可用 `SURGE_WATCHDOG_SWIFT_SDK` 指向另一套已安装的 macOS SDK。当前构建目标为 arm64，最低系统版本来自 App 的 `Info.plist`。

## Developer ID 签名与 Apple 公证

正式签名需要 Apple Developer Program 中的 **Developer ID Application** 证书及其私钥。查看本机可用身份：

```sh
security find-identity -v -p codesigning
```

构建带 Hardened Runtime 和安全时间戳的应用：

```sh
export SURGE_WATCHDOG_SIGN_IDENTITY='Developer ID Application: Your Name (TEAMID)'
./scripts/build-ui-helper.sh
```

首次配置公证凭据时，交互式写入钥匙串，避免把密码直接写入命令历史或项目配置：

```sh
xcrun notarytool store-credentials surge-watchdog-notary
```

随后签名、上传公证、装订 ticket 并重新打包：

```sh
export SURGE_WATCHDOG_SIGN_IDENTITY='Developer ID Application: Your Name (TEAMID)'
export SURGE_WATCHDOG_NOTARY_PROFILE='surge-watchdog-notary'
./scripts/package-release.sh
```

产物位于 `build/release/Surge-Watchdog-<version>.zip`。安装脚本也接受 `SURGE_WATCHDOG_SIGN_IDENTITY`。

## GitHub Actions 发布

| 工作流 | 触发方式 | 工作内容 |
| --- | --- | --- |
| Test | 仓库所有者推送 `main`，或手动触发 | 隐私检查、构建和测试 |
| Release | 仓库所有者推送 `vX.Y.Z` 标签 | 测试、Developer ID 签名、Apple 公证、装订、发布 ZIP 和 SHA-256 |

外部 PR 不自动触发工作流。首次触发者和重新运行者都必须是 `deepcoldy`；Fork 自行使用时，需要审查并调整相应的所有者限制。

发布提交必须属于 `main`，标签版本必须与 `Info.plist` 一致。先推送版本更新并确认测试通过，再创建新的版本标签；不要覆盖已经发布的标签。

`release` GitHub Environment 需要以下 Secrets：

- `DEVELOPER_ID_APPLICATION_P12_BASE64`
- `DEVELOPER_ID_APPLICATION_P12_PASSWORD`
- `APPLE_API_KEY_ID`
- `APPLE_API_ISSUER_ID`
- `APPLE_API_KEY_P8_BASE64`

发布在 GitHub 托管的临时 macOS Runner 上完成，不运行本机安装器或真实网关检查，不读取家庭网关配置和日志。工作流结束时清理签名凭据与临时钥匙串。

**Runner 在发版期间能接触签名私钥。** 构建和签名仍在同一个 Job 内；如果恶意代码被合并进发布提交，仅靠 Secrets 加密并不能阻止它读取或外传凭据。合并 PR、修改工作流和发布前仍需审查代码。详见 [安全策略](../SECURITY.md)。

## 提交前检查

```sh
python3 scripts/check-source-privacy.py
git diff --check
```

不要提交真实运行配置、日志、私钥或任何发布凭据。项目所有者的提交使用 GitHub noreply 邮箱。

涉及应用生命周期的改动，应保留现有回归测试：主窗口按需创建，关闭后释放，日志仅在界面需要时读取，避免引入后台 SwiftUI 布局循环或重复刷新。
