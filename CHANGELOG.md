# Changelog

Notable changes are recorded here. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow [Semantic Versioning](https://semver.org/).

## [0.0.1] - 2026-11-06

First public version.

### Added

- Control a nearby Mac or PC by pushing the pointer through a screen edge, and be controlled by one
- Drag canvas for arranging devices, direct switching shortcuts and locking to the current screen
- Pairing with a six-digit code, and encrypted connections
- Optional clipboard and file sync (off by default)
- Launch at login, corner protection and pausing during full-screen apps
- English, Simplified Chinese and Japanese interface

### Known issues

- During secure input (a focused password field, for example), keystrokes still reach the local window while controlling another device.
- Settings, trusted devices and the arrangement are decoded as a whole, so one damaged field resets that set to its defaults.
- While a peer expires from the core mid-connection, "Connecting" may not be cancellable (a narrow race).
- An edge entrance shorter than about 50 points in a screen corner is fully blocked by corner protection.
- A clipboard holding only unknown types, such as RTF, clears this Mac's clipboard before writing.
- Error reasons from the core appear in English in the Chinese and Japanese interfaces.
- There are no usage descriptions for the Desktop, Documents and Downloads folders yet.
- A file copied in Finder is sent as a file, not as an image, so it cannot be pasted as a picture on the other device.
- Modifier mapping: Windows can choose per key; macOS only has a switch to keep or swap the Mac's shortcuts.
