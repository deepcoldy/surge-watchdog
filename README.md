# Surge Watchdog

一个面向 macOS 的 Surge 家庭网关守护应用。它常驻菜单栏，定期检查 Surge 主程序、Gateway VM、DHCP 和 Fake DNS；连续异常达到阈值后，会按安全顺序恢复 Surge 并验证家庭网络是否真正恢复。

## 产品界面

安装后的应用位于：

```text
~/Applications/Surge Watchdog.app
```

点击菜单栏的网关恢复图标会显示原生菜单，可打开主界面、立即检查、暂停或继续监控、运行 UI 安全探测、打开日志目录，以及完全退出应用。

- **概览**：健康状态、Gateway VM 地址、最近检查时间、立即检查和 UI 安全探测。
- **监控日志**：最新记录显示在最上方；可查看最近 500 行、手动刷新并打开按日日志目录。
- **设置**：开始或暂停监控、登录启动、Surge UI 恢复、日志保留天数。
- **菜单栏状态**：模板图标会跟随系统菜单栏自动切换黑白外观，当前状态显示在提示文本和主界面中。

关闭主窗口不会退出应用，也不会停止后台监控。需要完全退出菜单栏进程时，可使用菜单栏菜单或“设置”页的“完全退出 Surge Watchdog”。即使菜单栏应用退出，已经启用的 launchd 健康检查仍会继续运行。

菜单栏应用在后台启动时不会提前创建隐藏的主窗口；关闭主窗口后也会释放对应的界面资源。日志只在打开主窗口或进入“监控日志”页面时读取，避免后台运行产生无意义的 SwiftUI 布局和文件读取负担。

## 检查和恢复链

后台默认每 10 秒执行一次检查：

1. Surge 进程是否存在。
2. 从 `dhcpd/server.json` 动态读取 `useVMNET`、`useDHCP`、Gateway VM IP 和接口。
3. Surge DHCP 进程是否存活，Gateway VM 是否具有有效的 ARP 邻居。
4. `198.18.0.2` 是否响应 Fake DNS 请求。

默认连续失败 3 次后开始恢复；两次恢复至少间隔 120 秒，每小时最多 3 次，避免重启风暴。

恢复顺序：

1. 如果显式启用了 Surge UI 恢复并且 Surge 正在运行，优先做成本较低的定向恢复。
2. 如果“网关模式”已经开启，打开齿轮菜单并执行“重启服务”。
3. 如果“网关模式”已经关闭，按 Surge 自带向导依次选择有线网络接口、启用 IPv4 DHCP，并在向导结束后确认主开关真的恢复为开启状态。
4. UI 操作完成后再次执行完整健康检查，而不是把“点击成功”当成网络已经恢复。
5. 定向恢复不可用或失败时，再调用 Surge 官方 `surge-cli --raw stop` 安全停止；CLI 失败时只发送普通 `SIGTERM`，永远不使用 `SIGKILL`。
6. 重新打开 Surge，并在 60 秒内重复完整健康检查；必要时可在重启后再尝试一次定向 UI 恢复。

关闭网关模式后的向导恢复只会接受 `Ethernet / 以太网` 接口，且不会修改静态地址、子网、路由器、DNS、IPv6 RA、VM 网关或 DHCP 地址池等字段。遇到未知页面、未知弹窗或接口不匹配时会立即停止，并转入完整应用恢复链。

Gateway VM IP 每次都从 Surge 状态文件重新发现，不依赖固定地址。DNS 检查使用保留域名 `surge-watchdog.invalid`，不依赖公网连通性。

## 安装

```sh
cd ~/iserver/surge-watchdog
./scripts/test.sh
./scripts/install.sh
```

安装器会：

- 构建并安装 `Surge Watchdog.app`。
- 安装后台检查器到 `~/Library/Application Support/surge-watchdog/`。
- 保留已有配置并补充新增默认项。
- 加载健康检查 LaunchAgent。
- 默认创建登录后启动菜单栏应用的 LaunchAgent。
- 将按日日志写入 `~/Library/Logs/Surge Watchdog/`。

安装前会运行只读健康检查；如果当前 Surge 本身不健康，安装器会拒绝改变 LaunchAgent，避免错误配置导致循环恢复。

## 辅助功能权限

辅助功能权限只用于可选的定向 Surge UI 恢复，日常健康检查、官方 CLI 恢复和重启整个 Surge 应用都不需要它。权限授予 `Surge Watchdog.app`，无需授权 Terminal。

正常使用时只需首次授权一次，并不会每次启动都询问。开发阶段之所以曾反复授权，是因为每轮调试都替换了使用临时 ad-hoc 签名的应用二进制；macOS 会把代码哈希变化视为应用身份变化。如果系统设置显示开关已开启但应用仍判断未授权，请使用应用中的“修复授权…”：它只清理 Surge Watchdog 自己的旧 TCC 条目，再由当前版本重新发起授权。安装器不会覆盖同版本应用，因此普通重启和重复安装同版本都不会清除权限。正式发布版本使用稳定的 Developer ID 签名，同一签名身份下的升级可以保持稳定的权限身份。

授权后必须先在“概览”运行一次 **UI 安全探测**。探测会：

- 自动打开 Surge 主窗口并切换到“设备”。
- 读取“网关模式”状态。
- 通过齿轮的真实屏幕坐标打开菜单，确认能找到“重启服务”。
- 关闭菜单，但不会切换网关模式，也不会重启服务。

只有探测成功后，主界面才允许开启“Surge UI 恢复”。应用版本发生变化时，安装器会主动关闭旧版本的 UI 恢复开关并清除探测结果；新版本重新探测成功后才能再次启用。

如果 Surge 存在模态弹窗，应用只会关闭带有“稍后 / 取消 / 关闭 / 跳过”等明确无副作用按钮的弹窗。未知弹窗会停止操作并记录错误，避免误点升级、导入、删除或授权确认。

## 监控与开机启动

“自动监控与恢复”写入持久配置。关闭后 launchd 仍可轻量唤醒检查器，但检查器会立即退出，不做检测或恢复；重新开启会立即执行一次检查。

“登录后在菜单栏启动”控制：

```text
~/Library/LaunchAgents/com.shenhan.surge-watchdog.app.plist
```

它只控制菜单栏应用是否在登录后出现，不影响后台健康检查开关。

## 日志与自动清理

按日日志目录：

```text
~/Library/Logs/Surge Watchdog/
```

默认保留 7 天，可在设置中调整为 1–90 天。界面按时间倒序显示，最新记录位于最上方。后台检查器每小时至多执行一次清理，菜单栏应用打开日志时也会补充清理。旧版本的 `~/Library/Logs/surge-watchdog.log` 会继续显示，但新日志写入按日文件。

## 配置

安装后的配置位于：

```text
~/Library/Application Support/surge-watchdog/config
```

常用设置均可在应用中修改。高级参数仍可直接编辑，包括失败阈值、恢复冷却、每小时恢复上限和验证时长。

项目根目录只保留可提交的 `config.example` 模板；安装器会把实际配置创建并保存在上述 Application Support 目录。不要在项目根目录保存真实运行配置或凭据。

命令行只读检查仍然可用：

```sh
~/Library/Application\ Support/surge-watchdog/bin/surge-watchdog --status
```

## 应用签名与公证

没有指定签名身份时，构建脚本会继续使用 ad-hoc 签名，仅适合本机开发。正式签名需要 Apple Developer Program 中的 **Developer ID Application** 证书及其私钥；当前钥匙串可用身份可用下列命令查看：

如果本机刚更新过 Command Line Tools，Swift 编译器与默认 SDK 暂时不匹配，可通过 `SURGE_WATCHDOG_SWIFT_SDK` 指向另一套已安装的 macOS SDK；未设置时仍使用系统默认 SDK。

```sh
security find-identity -v -p codesigning
```

证书安装完成后，可直接构建带 Hardened Runtime 和安全时间戳的应用：

```sh
export SURGE_WATCHDOG_SIGN_IDENTITY='Developer ID Application: Your Name (TEAMID)'
./scripts/build-ui-helper.sh
```

首次配置公证凭据时，把 Apple ID 的 app-specific password 安全写入钥匙串，不要保存到项目配置：

```sh
xcrun notarytool store-credentials surge-watchdog-notary \
  --apple-id 'you@example.com' \
  --team-id 'TEAMID' \
  --password 'APP-SPECIFIC-PASSWORD'
```

随后生成签名、上传公证、装订 ticket 并重新打包：

```sh
export SURGE_WATCHDOG_SIGN_IDENTITY='Developer ID Application: Your Name (TEAMID)'
export SURGE_WATCHDOG_NOTARY_PROFILE='surge-watchdog-notary'
./scripts/package-release.sh
```

产物位于 `build/release/Surge-Watchdog-<version>.zip`。安装脚本也接受同一个 `SURGE_WATCHDOG_SIGN_IDENTITY` 环境变量，并会拒绝用 ad-hoc 构建覆盖已正式签名的应用。

### GitHub Release 自动发布

仓库包含两条 GitHub Actions 工作流：普通提交运行 `.github/workflows/test.yml`；推送与 `Info.plist` 版本一致的 `v*` 标签时，`.github/workflows/release.yml` 会在 GitHub 托管的临时 macOS Runner 上完成测试、Developer ID 签名、Apple 公证、ticket 装订，并发布 ZIP 与 SHA-256 到 GitHub Release。

`release` GitHub Environment 需要以下 secrets：

- `DEVELOPER_ID_APPLICATION_P12_BASE64`
- `DEVELOPER_ID_APPLICATION_P12_PASSWORD`
- `APPLE_API_KEY_ID`
- `APPLE_API_ISSUER_ID`
- `APPLE_API_KEY_P8_BASE64`

发布时只提交版本标签，例如：

```sh
git tag -a v2.2.0 -m 'Surge Watchdog 2.2.0'
git push origin v2.2.0
```

工作流不会运行安装器或本机健康检查，也不会读取家庭网关配置与日志。详细边界见 `SECURITY.md`。仓库若为私有，Release 也只对有仓库访问权限的用户可见；仓库改为公开时，Release 会随之公开。

## 安全边界

- 不使用 `sudo`，不修改 Surge 配置、UniFi 配置或系统路由。
- 不依赖公网完成本地健康检查与 UI 兜底。
- UI 恢复默认关闭，并要求辅助功能权限和成功探测两道门槛；应用升级后必须重新探测。
- 所有恢复都受连续失败阈值、冷却时间和每小时上限约束。
- 整台 Mac 断电、死机、网卡失效或用户会话锁定时，UI 自动化无法工作。
- 本项目负责恢复 Surge，不会自动把 UniFi 客户端路由切换到直连网关。

## 卸载

```sh
cd ~/iserver/surge-watchdog
./scripts/uninstall.sh
```

卸载会停止两个 LaunchAgent，并删除我们安装的应用和运行脚本；配置、状态和日志默认保留，便于排查或重新安装。

## License

MIT
