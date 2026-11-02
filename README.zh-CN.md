# LinkCursor for macOS

[English](README.md) | 简体中文

SwiftUI/AppKit 客户端，macOS 14 及以上；Rust Core（[rinflow-core](https://github.com/rinflow-dev/rinflow-core)）需克隆到本工程旁边，文件夹名为 `linkcursor-core`（即 `../linkcursor-core`）。

## 本地开发

```sh
make build
make run
make test
```

`make run` 会退出并重新启动当前开发版。`Makefile` 优先使用钥匙串中的 Apple Development 证书，使辅助功能授权在重新构建后保持有效。无证书的临时签名适合编译测试，但重新构建后可能需要重新授权。

增删 Swift 文件后，可运行 `ruby scripts/generate-xcodeproj.rb` 重新生成工程（需要 Ruby `xcodeproj` gem）。生成器会重建 Xcode 工程，不保留手动添加的工程设置。

## 首次使用

1. 在同一局域网的另一台设备启动 LinkCursor。
2. 为本应用授予辅助功能权限，再回到主窗口刷新。没有权限仍可发现和配对设备，但不能共享键鼠。
3. 连接新设备，核对两端的六位配对码并分别确认。
4. 拖动设备排列，或在设备行选择位置。默认需推出边缘约 30 点并满 150 毫秒才切换（停在边缘也会完成），切换后 20 秒内来回无阻力；屏幕角落保留给菜单与触发角。
5. `⌃⌥⇧` 加方向键可直接切换设备；`⌃⌥Esc` 随时释放控制；`⌃⌥L` 锁定或解锁当前屏幕。

菜单栏可重新打开主窗口、暂停键鼠共享、切换剪贴板同步和管理连接。暂停键鼠不会断开设备；剪贴板由独立开关控制。

剪贴板与文件同步默认关闭。开启后，文字/图片随控制切换同步；与 Windows 一致，512 MB 以内的文件自动接收，更大的先询问，保存到 `~/Downloads/LinkCursor` 并放入剪贴板；超过 8 MiB 的图片会缩小后发送。关闭同步时，收到的剪贴板不会转发给其他设备。密码管理器标记为 concealed/transient 的内容不会上报。

设置中提供登录启动、快捷键组合、屏幕角落保护、全屏时暂停边缘切换、每设备指针/滚动速度、保持唤醒、一起锁定及中英文界面。语言切换在重新启动后生效。

## 签名与发布

| 用途 | 证书 | 命令 |
| --- | --- | --- |
| 日常开发 | Apple Development | `make run` |
| 给能手动放行的测试者 | Developer ID Application | `make candidate` |
| 公开分发 | Developer ID Application + 公证 | `make release` |

团队 ID 写在工程里（`998ZTJV2HQ`），平时不用传。没有证书的机器上 `make run` 自动改用临时签名。

首次发布前准备一次：

```sh
rustup target add aarch64-apple-darwin x86_64-apple-darwin
# 在 https://account.apple.com 生成 App 专用密码；命令会提示输入，密码存进钥匙串
xcrun notarytool store-credentials linkcursor-notary --apple-id 你的AppleID --team-id 998ZTJV2HQ
```

发布脚本只打包已提交的代码（`linkcursor-macos` 和 `linkcursor-core` 都要干净），每次干净构建；构建号取提交数，版本之间可以区分。脚本会检查 Developer ID、Hardened Runtime、安全时间戳和无调试权限，公证被拒时打印原因。产物在 `releases/`，公证成功后只保留可分发的 zip 和 SHA-256。

开发版和发布版的签名不同，macOS 把辅助功能权限分开记录。切换后如果键鼠共享不工作，重置后重新授权：

```sh
tccutil reset Accessibility com.linkcursor.mac
```

## 验收状态

见[发布清单](docs/release-checklist.md)。构建与单元测试通过不等于完成真实 Mac/Windows 联调，也不能证明不存在未知 bug。

## 许可证

[Mozilla Public License 2.0](LICENSE)。包含的第三方软件见 [THIRD_PARTY_NOTICES.txt](LinkCursor/Resources/THIRD_PARTY_NOTICES.txt)。
