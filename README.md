# Rinflow for macOS

[![License: MPL-2.0](https://img.shields.io/badge/License-MPL_2.0-brightgreen.svg)](LICENSE)

English | [简体中文](README.zh-CN.md)

Share one keyboard and mouse between nearby computers: push the pointer past a screen edge and your input goes to the other device. This is the SwiftUI/AppKit client, for macOS 14 or newer. It works with the [Windows client](https://github.com/rinflow-dev/rinflow-windows), and both build on [rinflow-core](https://github.com/rinflow-dev/rinflow-core).

> **Status: early MVP (0.1.0).** See the [changelog](CHANGELOG.md) for known issues.

## Development

You need Xcode 26 or newer and [Rust](https://rustup.rs). Clone [rinflow-core](https://github.com/rinflow-dev/rinflow-core) next to this repository, because Xcode builds it from `../rinflow-core`:

```sh
git clone https://github.com/rinflow-dev/rinflow-core.git
git clone https://github.com/rinflow-dev/rinflow-macos.git
```

```sh
make build
make run
make test
```

`make run` quits and restarts the development build. The `Makefile` prefers the Apple Development certificate in your keychain, so the Accessibility permission survives rebuilds. Without a certificate it uses an ad-hoc signature, which is fine for compiling and testing, but you may have to grant the permission again after each build.

After adding or removing Swift files, run `ruby scripts/generate-xcodeproj.rb` to regenerate the project (this needs the Ruby `xcodeproj` gem). The generator rebuilds the Xcode project and does not keep settings added by hand.

## First use

1. Start Rinflow on another device on the same local network.
2. Grant this app the Accessibility permission, then return to the main window and refresh. Without it you can still find and pair devices, but not share the keyboard and mouse.
3. Connect the new device, check that both show the same six-digit code, and confirm on each.
4. Drag the device into place, or choose a position in its row. By default, push about 30 points past the edge for 150 ms to cross (resting against the edge also completes it). For 20 seconds after crossing, moving back and forth meets no resistance. Screen corners stay free for menus and hot corners.
5. `⌃⌥⇧` plus an arrow key switches devices directly, `⌃⌥Esc` releases control at any time, and `⌃⌥L` locks or unlocks the current screen.

The menu bar can reopen the main window, pause keyboard and mouse sharing, toggle clipboard sync and manage connections. Pausing does not disconnect devices, and the clipboard has its own switch.

Clipboard and file sync is off by default. When on, text and images follow control between devices. As on Windows, files up to 512 MB are received automatically and larger ones ask first; they are saved to `~/Downloads/Rinflow` and placed on the clipboard. Images over 8 MiB are scaled down before sending. With sync off, a received clipboard is not forwarded to other devices. Content that password managers mark as concealed or transient is never reported.

Settings cover launch at login, shortcut combinations, corner protection, pausing edge crossing during full-screen apps, per-device pointer and scroll speed, keeping awake, locking together, and English or Chinese (the language changes after a restart).

## Signing and releases

| Purpose | Certificate | Command |
| --- | --- | --- |
| Everyday development | Apple Development | `make run` |
| Testers who can allow the app by hand | Developer ID Application | `make candidate` |
| Public distribution | Developer ID Application and notarization | `make release` |

The project's team ID is set in the Xcode project; pass `TEAM=XXXXXXXXXX` to use your own. On a machine without a certificate, `make run` falls back to an ad-hoc signature.

Before the first release, once:

```sh
rustup target add aarch64-apple-darwin x86_64-apple-darwin
# Create an app-specific password at https://account.apple.com. The command
# asks for it and stores it in the keychain.
xcrun notarytool store-credentials rinflow-notary --apple-id YOUR_APPLE_ID --team-id YOUR_TEAM_ID
```

The release script packages committed code only (both `rinflow-macos` and `rinflow-core` must be clean) and always builds from clean. The build number is the commit count, so builds can be told apart. It checks for the Developer ID signature, hardened runtime, secure timestamp and absence of debug entitlements, and prints the reason if notarization is rejected. Results land in `releases/`; after notarization only the distributable zip and its SHA-256 remain.

Development and release builds have different signatures, and macOS records the Accessibility permission separately for each. If sharing stops working after switching, reset and grant it again:

```sh
tccutil reset Accessibility com.rinflow.mac
```

Maintainers: see the [release checklist](docs/release-checklist.md). Passing builds and unit tests do not replace testing between a real Mac and PC.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md). Please report security problems as described in [SECURITY.md](SECURITY.md).

## License

Rinflow is licensed under the [Mozilla Public License 2.0](LICENSE). The third-party software it includes is listed in [THIRD_PARTY_NOTICES.txt](Rinflow/Resources/THIRD_PARTY_NOTICES.txt).
