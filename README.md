# LinkCursor for macOS

SwiftUI/AppKit 客户端，macOS 14 及以上；Rust Core 与本工程并列放在 `../linkcursor-core`。

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

## 发布候选包

先安装两个 Rust 编译目标：

```sh
rustup target add aarch64-apple-darwin x86_64-apple-darwin
TEAM=YOUR_TEAM_ID scripts/package-release.sh
```

脚本构建 Apple Silicon + Intel 通用版本，启用 Hardened Runtime 和安全时间戳，不注入调试权限，验证签名与两种架构，然后输出 `releases/*-unnotarized.zip` 和 SHA-256 校验值。

公开发布前，使用已经配置好的 notarytool Keychain profile：

```sh
TEAM=YOUR_TEAM_ID NOTARY_PROFILE=YOUR_PROFILE scripts/package-release.sh
```

脚本会提交公证、staple 并验证 Gatekeeper，通过后生成不带 `unnotarized` 后缀的发布 ZIP。不要将密码或 App Store Connect 私钥写进仓库。

应用图标复用 Windows 的品牌图形，源文件为 `LinkCursor/Resources/AppIcon.svg`；安装 librsvg 后可用 `scripts/generate-icon.sh` 重新生成 `.icns`。正常构建不需要图标工具。

## 验收状态

见 [MVP 审查记录](MVP_REVIEW.md)。构建与单元测试通过不等于完成真实 Mac/Windows 联调，也不能证明不存在未知 bug。
