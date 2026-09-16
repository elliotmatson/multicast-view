import XCTest
import MulticastCore

/// A minimal classic-BPF interpreter, so the filter can be executed against real
/// frames in a unit test. A wrong jump offset does not make the kernel complain
/// -- it silently captures the wrong traffic -- so the only way to know the
/// offsets are right is to run the program.
struct BPFInterpreter {
    enum Failure: Error { case badInstruction(Int), ranOffTheEnd }

    static func run(_ program: [BPFInstruction], on frame: [UInt8]) throws -> UInt32 {
        var accumulator: UInt32 = 0
        var index = 0
        var steps = 0

        while index < program.count {
            steps += 1
            if steps > 10_000 { throw Failure.ranOffTheEnd }
            let instruction = program[index]

            func load(_ width: Int) -> UInt32? {
                let offset = Int(instruction.k)
                guard offset >= 0, offset + width <= frame.count else { return nil }
                var value: UInt32 = 0
                for byteIndex in 0..<width { value = (value << 8) | UInt32(frame[offset + byteIndex]) }
                return value
            }

            switch instruction.code {
            case BPFOpcode.loadByteAbsolute:
                // A load past the end of the packet terminates the filter with 0,
                // which is what the kernel does.
                guard let value = load(1) else { return 0 }
                accumulator = value
            case BPFOpcode.loadHalfAbsolute:
                guard let value = load(2) else { return 0 }
                accumulator = value
            case BPFOpcode.loadWordAbsolute:
                guard let value = load(4) else { return 0 }
                accumulator = value
            case BPFOpcode.andConstant:
                accumulator &= instruction.k
            case BPFOpcode.jumpEqualConstant:
                index += 1 + Int(accumulator == instruction.k ? instruction.jt : instruction.jf)
                continue
            case BPFOpcode.jumpAlways:
                index += 1 + Int(instruction.k)
                continue
            case BPFOpcode.returnConstant:
                return instruction.k
            default:
                throw Failure.badInstruction(index)
            }
            index += 1
        }
        throw Failure.ranOffTheEnd
    }
}

final class BPFAssemblerTests: XCTestCase {
    /// Offsets are counted from the instruction *after* the jump.
    func testJumpOffsetsAreRelativeToTheFollowingInstruction() throws {
        let program = try BPFAssembler.assemble([
            .loadHalf(offset: 12),                                  // 0
            .jumpEqual(0x0800, ifEqual: "hit", otherwise: "miss"),  // 1
            .returnConstant(111),                                   // 2 (unreachable filler)
            .label("hit"),
            .returnConstant(222),                                   // 3
            .label("miss"),
            .returnConstant(0),                                     // 4
        ])
        XCTAssertEqual(program.count, 5)
        // From index 1, "hit" is at 3: 3 - (1 + 1) = 1. "miss" is at 4: 4 - 2 = 2.
        XCTAssertEqual(program[1].jt, 1)
        XCTAssertEqual(program[1].jf, 2)
    }

    func testFallThroughIsOffsetZero() throws {
        let program = try BPFAssembler.assemble([
            .loadHalf(offset: 12),
            .jumpEqual(0x8100, ifEqual: "tagged", otherwise: nil),
            .returnConstant(0),
            .label("tagged"),
            .returnConstant(65535),
        ])
        XCTAssertEqual(program[1].jf, 0, "a nil target means fall through to the next instruction")
        XCTAssertEqual(program[1].jt, 1)
    }

    func testUnknownLabelIsRejected() {
        XCTAssertThrowsError(try BPFAssembler.assemble([
            .jumpEqual(1, ifEqual: "nowhere", otherwise: nil),
            .returnConstant(0),
        ])) { error in
            XCTAssertEqual(error as? BPFAssemblyError, .unknownLabel("nowhere"))
        }
    }

    func testJumpBeyondConditionalReachIsRejected() {
        var steps: [BPFStep] = [.jumpEqual(1, ifEqual: "far", otherwise: nil)]
        for _ in 0..<300 { steps.append(.returnConstant(0)) }
        steps.append(.label("far"))
        steps.append(.returnConstant(1))
        XCTAssertThrowsError(try BPFAssembler.assemble(steps)) { error in
            XCTAssertEqual(error as? BPFAssemblyError, .jumpTooFar("far"))
        }
    }

    func testLabelsDoNotOccupyInstructionSlots() throws {
        let program = try BPFAssembler.assemble([
            .label("a"), .label("b"),
            .returnConstant(0),
        ])
        XCTAssertEqual(program.count, 1)
    }
}

final class MulticastFilterTests: XCTestCase {
    private var program: [BPFInstruction] = []

    override func setUp() {
        program = (try? MulticastFilter.program(snapshotLength: 2048)) ?? []
    }

    private func verdict(_ frame: [UInt8]) throws -> UInt32 {
        try BPFInterpreter.run(program, on: frame)
    }

    func testProgramAssembles() {
        XCTAssertFalse(program.isEmpty)
    }

    func testAcceptsUntaggedIPv4Multicast() throws {
        let frame = FrameBuilder.udpFrame(source: "10.10.1.50", destination: "239.255.0.12",
                                          sourcePort: 5568, destinationPort: 5568)
        XCTAssertEqual(try verdict(frame), 2048)
    }

    func testAcceptsAcrossTheWholeMulticastRange() throws {
        for group in ["224.0.0.1", "224.0.0.251", "232.1.2.3", "233.1.2.3",
                      "239.69.0.1", "239.255.255.250", "239.255.255.255"] {
            let frame = FrameBuilder.udpFrame(source: "10.0.0.1", destination: group,
                                              sourcePort: 1234, destinationPort: 5568)
            XCTAssertEqual(try verdict(frame), 2048, "should accept \(group)")
        }
    }

    /// The boundaries of 224.0.0.0/4. These are what a wrong mask would get wrong.
    func testRejectsAddressesJustOutsideTheMulticastRange() throws {
        for address in ["223.255.255.255", "240.0.0.0", "255.255.255.255", "10.0.0.1"] {
            var frame = FrameBuilder.udpFrame(source: "10.0.0.1", destination: "239.255.0.12",
                                              sourcePort: 1234, destinationPort: 5568)
            // Overwrite the IP destination in place: 14 (Ethernet) + 16 (IP dst).
            let bytes = IPv4Address(address)!.bytes
            frame[30] = bytes.0; frame[31] = bytes.1; frame[32] = bytes.2; frame[33] = bytes.3
            XCTAssertEqual(try verdict(frame), 0, "should reject \(address)")
        }
    }

    func testRejectsUnicast() throws {
        let frame = FrameBuilder.udpFrame(source: "10.10.1.50", destination: "10.10.1.60",
                                          sourcePort: 5568, destinationPort: 5568)
        XCTAssertEqual(try verdict(frame), 0)
    }

    func testRejectsNonIPv4() throws {
        // ARP, and an IPv6 frame.
        for etherType in [UInt16(0x0806), UInt16(0x86DD)] {
            let frame = FrameBuilder.ethernet(destination: FrameBuilder.mac("ff:ff:ff:ff:ff:ff"),
                                              source: FrameBuilder.mac("00:1d:c1:aa:bb:cc"),
                                              etherType: etherType,
                                              payload: [UInt8](repeating: 0xEE, count: 64))
            XCTAssertEqual(try verdict(frame), 0, "should reject ethertype \(etherType)")
        }
    }

    func testAcceptsSingleVLANTaggedMulticast() throws {
        let frame = FrameBuilder.udpFrame(source: "10.10.1.50", destination: "239.255.0.12",
                                          sourcePort: 5568, destinationPort: 5568, vlans: [120])
        XCTAssertEqual(try verdict(frame), 2048, "a tagged frame must not be missed")
    }

    func testRejectsSingleVLANTaggedUnicast() throws {
        let frame = FrameBuilder.udpFrame(source: "10.10.1.50", destination: "10.10.1.60",
                                          sourcePort: 5568, destinationPort: 5568, vlans: [120])
        XCTAssertEqual(try verdict(frame), 0)
    }

    func testAcceptsStackedVLANTaggedMulticast() throws {
        var frame: [UInt8] = []
        frame += IPv4Address("239.255.0.12")!.ethernetMulticastMAC.bytes
        frame += FrameBuilder.mac("00:1d:c1:aa:bb:cc").bytes
        frame += FrameBuilder.bigEndian16(EtherType.providerBridging)
        frame += FrameBuilder.bigEndian16(400)
        frame += FrameBuilder.bigEndian16(EtherType.vlan)
        frame += FrameBuilder.bigEndian16(120)
        frame += FrameBuilder.bigEndian16(EtherType.ipv4)
        frame += FrameBuilder.ipv4(source: IPv4Address("10.0.0.1")!,
                                   destination: IPv4Address("239.255.0.12")!,
                                   protocolNumber: IPProtocol.udp,
                                   payload: FrameBuilder.udp(sourcePort: 5568, destinationPort: 5568, payload: []))
        XCTAssertEqual(try verdict(frame), 2048)
    }

    func test8021adSingleTagIsAccepted() throws {
        let frame = FrameBuilder.udpFrame(source: "10.0.0.1", destination: "239.69.0.1",
                                          sourcePort: 5004, destinationPort: 5004,
                                          vlans: [300])
        var tagged = frame
        // Swap the TPID from 0x8100 to 0x88A8.
        tagged[12] = 0x88; tagged[13] = 0xA8
        XCTAssertEqual(try verdict(tagged), 2048)
    }

    /// A truncated frame must make the filter return 0, not read past the end.
    func testTruncatedFramesAreRejectedNotRead() throws {
        let full = FrameBuilder.udpFrame(source: "10.0.0.1", destination: "239.255.0.12",
                                         sourcePort: 5568, destinationPort: 5568)
        for length in [0, 1, 12, 13, 14, 20, 29, 33] {
            XCTAssertEqual(try verdict(Array(full.prefix(length))), 0, "length \(length)")
        }
        // 34 bytes is exactly enough to reach the end of the IP destination.
        XCTAssertEqual(try verdict(Array(full.prefix(34))), 2048)
    }

    func testSnapshotLengthIsWhatIsReturned() throws {
        let short = try MulticastFilter.program(snapshotLength: 128)
        let frame = FrameBuilder.udpFrame(source: "10.0.0.1", destination: "239.255.0.12",
                                          sourcePort: 5568, destinationPort: 5568)
        XCTAssertEqual(try BPFInterpreter.run(short, on: frame), 128)
    }
}
