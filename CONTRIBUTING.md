# Contributing to Rinflow for macOS

Thanks for your interest. You need Xcode 26 or newer and [Rust](https://rustup.rs). Clone [rinflow-core](https://github.com/rinflow-dev/rinflow-core) next to this repository, because Xcode builds it from source.

## Building and testing

```sh
make run    # build and start
make test   # before opening a pull request
make log    # follow the app's log
```

Without an Apple Development certificate the app is signed ad hoc, which is enough for building and testing, though the Accessibility permission may need granting again after each build.

The Xcode project is generated. After adding or removing files, or to change a build setting, edit [scripts/generate-xcodeproj.rb](scripts/generate-xcodeproj.rb) and run it (this needs the Ruby `xcodeproj` gem); changes made by hand in Xcode are lost.

UI text is in String Catalogs: `Rinflow/Resources/Localizable.xcstrings`, and `InfoPlist.xcstrings` for the Info.plist. Write new text in Chinese in the code (`Text("…")`, `String(localized: "…")`), run `make i18n` to add it to the catalog with its Chinese entry (a build in Xcode adds it without one, and Chinese then falls back to English), then translate it into English and Japanese. `make test` fails while a string is untranslated or no longer used. Pass a `LocalizedStringResource` or `LocalizedStringKey`, not a `String`, to views that show a literal: a literal given as a `String` is never translated.

If `rinflow-core/Cargo.lock` changes, regenerate `Rinflow/Resources/THIRD_PARTY_NOTICES.txt` as shown in [its script](https://github.com/rinflow-dev/rinflow-core/blob/main/scripts/third-party-notices.ps1).

## Commits and pull requests

- Keep pull requests focused, and open an issue first for larger changes.
- Use [Conventional Commits](https://www.conventionalcommits.org/) for messages: `feat: ...`, `fix: ...`, `docs: ...`, `refactor: ...`, `test: ...`, `build: ...`, `ci: ...`, `chore: ...`.
- Add user-visible changes to `CHANGELOG.md`.

## Protocol and ABI changes

The clients link `rinflow-core` from source. A change to the wire protocol or the C ABI affects every client, so bump the versions as described in [the protocol documentation](https://github.com/rinflow-dev/rinflow-core/blob/main/docs/protocol.md#changing-the-protocol-or-abi) and update the clients in step.

## License

Rinflow is licensed under the [Mozilla Public License 2.0](LICENSE). Unless you state otherwise, your contribution is licensed the same way. New source files start with this notice, in the file's comment syntax:

```
This Source Code Form is subject to the terms of the Mozilla Public
License, v. 2.0. If a copy of the MPL was not distributed with this
file, You can obtain one at https://mozilla.org/MPL/2.0/.
```

Please do not copy code from projects with incompatible licenses. Other input-sharing projects may be consulted for how they behave, but their code may not be reused unless its license allows it.

This project follows the [Contributor Covenant](CODE_OF_CONDUCT.md).
