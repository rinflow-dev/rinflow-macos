# Rinflow for macOS

English | [简体中文](README.zh-CN.md) | [日本語](README.ja.md)

Rinflow shares one keyboard and mouse between computers on a local network. Move the pointer past a screen edge to control the next device.

This is the macOS client. It works with the [Windows client](https://github.com/rinflow-dev/rinflow-windows) and is built on [rinflow-core](https://github.com/rinflow-dev/rinflow-core).

**Status:** early development. There are no binary releases yet. Known issues are listed in the [changelog](CHANGELOG.md).

## Features

- Control other devices, or be controlled by them, by crossing a screen edge
- Drag devices into place around your displays
- Encrypted connections, with six-digit pairing
- Optional clipboard and file sync, off by default
- Launch at login, shortcuts for switching devices, and locking to the current screen

## Building

Requires macOS 14 or later, Xcode 26 or later, and [Rust](https://rustup.rs).

```sh
git clone https://github.com/rinflow-dev/rinflow-core.git
git clone https://github.com/rinflow-dev/rinflow-macos.git
cd rinflow-macos
make run
```

`make test` runs the tests. Without an Apple Development certificate the app is signed ad hoc, and the Accessibility permission may have to be granted again after each build.

## Usage

1. Start Rinflow on both devices, on the same network, and grant it the Accessibility permission.
2. Connect the device, and check that both show the same six-digit code.
3. Drag the device to the side of your screen where it sits.
4. Push the pointer past that edge. **⌃⌥Esc** brings control back.

## Documentation

- [Release checklist](docs/release-checklist.md): signing, notarization and manual tests
- [Core documentation](https://github.com/rinflow-dev/rinflow-core#documentation)

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md). To report a vulnerability, see [SECURITY.md](SECURITY.md).

## License

[Mozilla Public License 2.0](LICENSE). Third-party software is listed in [THIRD_PARTY_NOTICES.txt](Rinflow/Resources/THIRD_PARTY_NOTICES.txt).
