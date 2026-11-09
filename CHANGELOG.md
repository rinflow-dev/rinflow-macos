# Changelog

Notable changes are recorded here. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow [Semantic Versioning](https://semver.org/).

## [Unreleased]

### Fixed

- While secure input is on (a focused password field, Terminal's Secure Keyboard Entry), the pointer no longer leaves this Mac, and comes back if it turns on meanwhile: keystrokes meant for the other device went to the local window. A message names the app holding it.
- One damaged setting, paired device, placement or known device no longer resets the whole set: only that entry falls back.
- A clipboard from another device holding nothing this Mac can paste (only RTF, say) no longer clears this Mac's clipboard.
- Every reason and error from the core is shown in the interface's language (the core's new `reason_code`), not in English.
- Large clipboards (images up to 8 MB) are encoded and decoded off the main thread, which also runs the input event tap, and the pasteboard is no longer read inside the tap at the moment the pointer leaves.
- Changing the arrangement while this Mac drives another device (on either device, for example by dragging screens with this very pointer) no longer gives control back to the Mac: the pointer stays where it is and follows the new arrangement.

### Added

- Updates (Sparkle) from updates.rinflow.com, which also works where GitHub does not: checked automatically, or with **检查更新…** in the menu bar and in Settings. Updates are signed and keep the Accessibility permission.
- Modifier keys when a PC controls this Mac: Mac style, keep key positions, or a choice for each of Ctrl, the Windows key and Alt, as on Windows. The former switch carries over.
- Event tap stalls (events waiting over 30 ms, or taking over 4 ms to handle) and tap timeouts are logged (`make log`), to measure input latency.

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

- While a peer expires from the core mid-connection, "Connecting" may not be cancellable (a narrow race).
- An edge entrance shorter than about 50 points in a screen corner is fully blocked by corner protection.
- There are no usage descriptions for the Desktop, Documents and Downloads folders yet.
- A file copied in Finder is sent as a file, not as an image, so it cannot be pasted as a picture on the other device.
