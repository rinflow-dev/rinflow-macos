# Pasting a peer's files

Files copied on another device are pasted on this Mac with ⌘V in Finder (or any app that takes files) and only then travel: copying 20 GB on the PC sends nothing until it is pasted, and pasting shows Finder's own progress and can be cancelled there. As on Windows, where Explorer reads the Mac's files the same way (OLE virtual files).

## Why a File Provider

macOS has no lazy file paste for third parties. File promises work for drag and drop only: Finder never asks a pasteboard promise for its files. A lazily provided `public.file-url` is asked for on the main thread, which blocks the reader (clipboard managers read every copy at once), and macOS gives up after 120 s; it can only return a path that exists. What works is a real path whose bytes come when read: a File Provider placeholder, as iCloud Drive and Dropbox have. The pasteboard holds its URL; Finder copying it makes the system ask the extension for the contents.

## The parts

| Part | Where | Does |
|---|---|---|
| `RinflowFiles.appex` (`FileProvider/`) | `Contents/PlugIns` | Sandboxed. Lists clips as placeholders in one hidden domain, `clipboard`; fetches a file's bytes from the app when the system asks |
| `rinflow-files` (`FilesHelper/`) | `Contents/MacOS` | Registers the domain, signals the working set, waits for a clip's placeholders and prints their folder. A process that asks for a placeholder's URL is exempted from fetching placeholders it reads; this keeps the app from being that process |
| `RemoteFiles`, `FileServer`, `LocalCopy`, `Leases` (`Rinflow/Files/`) | the app | Turn the core's `files_available` into a clip, publish it or fetch it, write the pasteboard, serve the extension |
| `Shared/` | app, extension, helper, tests | `Clip` and its tree, item identifiers, the working set's anchor, the socket protocol |

The App Group `998ZTJV2HQ.com.rinflow.mac` (team-prefixed: no provisioning profile with Developer ID) holds `Clips/<id>.json`, one per peer copy, and `files.sock`.

## A copy, step by step

1. A peer copies files and hands control back. The core (with `on_demand_files`) reports `files_available` with the manifest and fetches nothing.
2. The app empties the pasteboard (a paste now gives nothing rather than the previous copy) and makes the copy a clip with a random ID.
3. Up to 16 MiB in all, the app fetches it at once into `~/Library/Caches/com.rinflow.mac/Pasted/<clip>` through one lease: a placeholder would cost more than the bytes. Larger, it writes `Clips/<clip>.json` and runs `rinflow-files publish`; the extension reports the clip's items through the working set, and the helper prints the clip's folder once its top-level placeholders exist (well under a second).
4. The pasteboard gets the top-level items' URLs, unless the user copied something else meanwhile.
5. Finder pastes: for each file the system calls the extension's `fetchContents`, which connects to `files.sock`, asks for the clip and entry, and writes the frames it gets into a temporary file it hands back. The app checks that the client is this extension by its signature, opens one lease for the clip (the core counts the paste as one transfer, with one progress), and reads 256 KiB at a time. The lease closes 10 s after the last file.
6. The next peer copy retires the one before last, once no paste of it runs: its clip file goes, the working set drops its folder, and its cached copy is deleted. A relaunch starts clean.

## When things go wrong

- The extension is turned off (System Settings › General › Login Items & Extensions; it is on by default), or the App Group is missing: every copy is fetched locally, asking first past 512 MB. `rinflow-files status` tells (exit 3), checked at launch, whenever Rinflow comes to the front and when Settings opens. Only then does Settings › General show "Shared Clipboard is off" with a button to that page of System Settings, and the 512 MB question mentions it; nothing asks a user who never turned it off.
- The peer copied something else, or left: the extension reports the item as gone (`noSuchItem`), which Finder shows as an error instead of retrying.
- The connection broke off, a read timed out, or the file changed on the peer: `serverUnreachable`, which can be tried again.
- Cancelled in Finder: the extension closes the socket, the app stops at its next write and closes the lease as cancelled.
- Sharing the clipboard turned off: every paste under way stops (`lc_core_revoke_file_streams`) and the clips are withdrawn.

## Known gaps

- A whole file is fetched before Finder gets it (no partial fetch): opening the first page of a 4 GB file waits for all of it. The core reads ranges already; `NSFileProviderPartialContentFetching` would use them.
- The same extension serves Debug and Release builds of the app on one Mac; run one at a time.
