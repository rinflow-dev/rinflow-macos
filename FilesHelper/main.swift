// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

// rinflow-files: the app's hands on its File Provider domain, as a separate
// process in Contents/MacOS. A process that asks the system for a
// placeholder's URL is no longer made to fetch the placeholders it reads, so
// the app itself never does: a pasted file it later sends on would read as
// empty instead of being fetched.
//
//   rinflow-files publish <clip> <name>…   after the app wrote Clips/<clip>.json:
//       registers the domain if needed, has the system list the clip, waits
//       until its top-level placeholders exist and prints the clip
//       folder's path. Exit 3: the user turned the extension off.
//   rinflow-files signal                   after the app removed clips
//   rinflow-files status                   registers the domain if needed;
//       exit 0 if the extension is on, 3 if the user turned it off
//   rinflow-files remove                   removes the domain and its files
//
// Exit 0 on success, 2 for bad arguments, 4 for any other failure (on stderr).

import FileProvider
import Foundation

let identifier = NSFileProviderDomainIdentifier(FilesGroup.domain)

func makeDomain() -> NSFileProviderDomain {
    let domain = NSFileProviderDomain(identifier: identifier, displayName: "Rinflow")
    domain.isHidden = true
    return domain
}

func fail(_ code: Int32, _ message: String) -> Never {
    FileHandle.standardError.write(Data("rinflow-files: \(message)\n".utf8))
    exit(code)
}

func registered() async throws -> NSFileProviderDomain? {
    try await NSFileProviderManager.domains().first { $0.identifier == identifier }
}

func manager() async throws -> NSFileProviderManager {
    if try await registered() == nil {
        try await NSFileProviderManager.add(makeDomain())
    }
    guard let manager = NSFileProviderManager(for: makeDomain()) else { fail(4, "no manager for the domain") }
    return manager
}

func publish(_ clip: String, names: [String]) async throws {
    let manager = try await manager()
    if let current = try await registered(), !current.userEnabled {
        fail(3, "the extension is turned off")
    }
    try await manager.signalEnumerator(for: .workingSet)
    // The folder's URL exists once the system has the clip from the working
    // set, its placeholders a moment later.
    let deadline = Date().addingTimeInterval(10)
    var folder: URL?
    while Date() < deadline {
        if folder == nil {
            folder = try? await manager.getUserVisibleURL(for: NSFileProviderItemIdentifier(ItemName.clipFolder(clip)))
        }
        if let folder, names.allSatisfy({ FileManager.default.fileExists(atPath: folder.appending(path: $0).path) }) {
            print(folder.path)
            return
        }
        try await Task.sleep(for: .milliseconds(50))
    }
    fail(4, folder == nil ? "the clip never appeared" : "its placeholders never appeared")
}

let arguments = Array(CommandLine.arguments.dropFirst())
do {
    switch arguments.first {
    case "publish" where arguments.count >= 3:
        try await publish(arguments[1], names: Array(arguments.dropFirst(2)))
    case "signal":
        try await manager().signalEnumerator(for: .workingSet)
    case "status":
        _ = try await manager()
        if let current = try await registered(), !current.userEnabled {
            fail(3, "the extension is turned off")
        }
    case "remove":
        if let domain = try await registered() {
            _ = try await NSFileProviderManager.remove(domain, mode: .removeAll)
        }
    default:
        fail(2, "usage: rinflow-files publish <clip> <name>… | signal | status | remove")
    }
} catch {
    fail(4, String(describing: error))
}
