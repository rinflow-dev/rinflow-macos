# Release checklist

What a macOS release needs. Unit tests and a passing build do not cover the manual checks.

## Building a release

| Purpose | Certificate | Command |
| --- | --- | --- |
| Everyday development | Apple Development | `make run` |
| Testers who can allow the app by hand | Developer ID Application | `make candidate` |
| Public distribution | Developer ID Application and notarization | `make release` |

The project's team ID is set in the Xcode project; pass `TEAM=XXXXXXXXXX` to use your own.

Before the first release, once:

```sh
rustup target add aarch64-apple-darwin x86_64-apple-darwin
# Create an app-specific password at https://account.apple.com. The command
# asks for it and stores it in the keychain.
xcrun notarytool store-credentials rinflow-notary --apple-id YOUR_APPLE_ID --team-id YOUR_TEAM_ID
```

The release script packages committed code only (both `rinflow-macos` and `rinflow-core` must be clean) and always builds from clean. The build number is the commit count. It checks for the Developer ID signature, hardened runtime, secure timestamp and absence of debug entitlements, and prints the reason if notarization is rejected. Results land in `releases/`: a disk image for Apple silicon (`arm64`) and one for Intel (`x64`), each holding the app and a link to Applications. With notarization each app is notarized and stapled first, so it opens offline once copied out, and then its image; only the distributable images and their SHA-256 files remain.

Development and release builds have different signatures, and macOS records the Accessibility permission separately for each. If sharing stops working after switching, reset and grant it again:

```sh
tccutil reset Accessibility com.rinflow.mac
```

## Signing

- [ ] Developer ID certificate is valid. Released builds carry a timestamp and keep working after it expires, but new ones cannot be signed; renew in Xcode › Settings › Accounts or the developer portal.
- [ ] A `notarytool` profile is configured, and `make release` ends in two notarized disk images

## Mac and Windows on real machines

- [ ] Both directions: double-click, drag, continuous motion, modifier key release, input methods, scroll speed
- [ ] Reconnection after a network drop and after sleep
- [ ] Several monitors, and game pointer lock
- [ ] System-wide shortcuts on a physical keyboard. Automation tools do not reliably trigger Carbon hot keys, so test these by hand.

## First run and system integration

- [ ] First install, granting and revoking permissions
- [ ] Launch at login, signing out and back in
- [ ] Locking together with the Mac's lock screen
- [ ] macOS 14 and Intel Macs

## Pairing and files

- [ ] Both devices starting a pairing at the same moment
- [ ] Several file confirmations expiring or being cancelled
- [ ] A large file transfer failing and recovering
