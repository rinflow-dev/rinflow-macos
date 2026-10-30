import XCTest

final class PeerTests: XCTestCase {
    func testIncomingConnectionsKeepDiscoveryMetadata() {
        let known = Peer(id: "pc", name: "Old", platform: "windows", address: "192.168.1.20", port: 42421,
                         displays: [.fallback])
        let incoming = Peer(id: "pc", name: "Renamed", platform: nil, address: "incoming", port: 42421, displays: [])
        let merged = incoming.mergingKnown(known)
        XCTAssertEqual(merged.name, "Renamed")
        XCTAssertEqual(merged.platform, "windows")
        XCTAssertEqual(merged.address, "192.168.1.20")
        XCTAssertEqual(merged.displays, [.fallback])
    }

    func testFreshDiscoveryReplacesOldNetworkAddress() {
        let old = Peer(id: "pc", name: "PC", platform: "windows", address: "old", port: 42421)
        let fresh = Peer(id: "pc", name: "PC", platform: "windows", address: "new", port: 42421)
        XCTAssertEqual(fresh.mergingKnown(old).address, "new")
        XCTAssertEqual(fresh.mergingKnown(nil), fresh)
    }
}
