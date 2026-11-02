# Release checklist

What has to be checked by hand before a macOS release. Unit tests and a passing build do not cover any of this.

## Signing

- [ ] Developer ID certificate is valid. Released builds carry a timestamp and keep working after it expires, but new ones cannot be signed; renew in Xcode › Settings › Accounts or the developer portal.
- [ ] A `notarytool` profile is configured, and `make release` ends in a notarized zip

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
