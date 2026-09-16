import XCTest
import MulticastCore

final class AddressTests: XCTestCase {
    func testDottedQuadRoundTrip() {
        let address = IPv4Address("239.255.0.12")
        XCTAssertNotNil(address)
        XCTAssertEqual(address?.description, "239.255.0.12")
        XCTAssertEqual(address?.raw, 0xEF_FF_00_0C)
    }

    func testRejectsMalformedText() {
        XCTAssertNil(IPv4Address("239.255.0"))
        XCTAssertNil(IPv4Address("239.255.0.256"))
        XCTAssertNil(IPv4Address("239.255.0.12.1"))
        XCTAssertNil(IPv4Address(""))
        XCTAssertNil(IPv4Address("239.255..12"))
        XCTAssertNil(IPv4Address("a.b.c.d"))
    }

    func testMulticastClassification() {
        XCTAssertTrue(IPv4Address("224.0.0.1")!.isMulticast)
        XCTAssertTrue(IPv4Address("239.255.255.255")!.isMulticast)
        XCTAssertFalse(IPv4Address("223.255.255.255")!.isMulticast)
        XCTAssertFalse(IPv4Address("240.0.0.1")!.isMulticast)
        XCTAssertTrue(IPv4Address("224.0.0.251")!.isLinkLocalControl)
        XCTAssertFalse(IPv4Address("224.0.1.1")!.isLinkLocalControl)
    }

    func testSubnetMatching() {
        let group = IPv4Address("239.69.1.2")!
        XCTAssertTrue(group.inSubnet(IPv4Address("239.69.0.0")!, prefix: 16))
        XCTAssertFalse(group.inSubnet(IPv4Address("239.255.0.0")!, prefix: 16))
        XCTAssertTrue(group.inSubnet(IPv4Address("239.0.0.0")!, prefix: 8))
        // /14 boundary: 239.192.0.0/14 covers 239.192 through 239.195.
        XCTAssertTrue(IPv4Address("239.195.255.255")!.inSubnet(IPv4Address("239.192.0.0")!, prefix: 14))
        XCTAssertFalse(IPv4Address("239.196.0.0")!.inSubnet(IPv4Address("239.192.0.0")!, prefix: 14))
    }
}
