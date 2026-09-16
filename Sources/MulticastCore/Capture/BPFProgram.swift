import Foundation

/// One classic-BPF instruction. Layout matches `struct bpf_insn`.
public struct BPFInstruction: Equatable {
    public let code: UInt16
    public let jt: UInt8
    public let jf: UInt8
    public let k: UInt32

    public init(code: UInt16, jt: UInt8 = 0, jf: UInt8 = 0, k: UInt32 = 0) {
        self.code = code
        self.jt = jt
        self.jf = jf
        self.k = k
    }
}

public enum BPFOpcode {
    // Loads
    public static let loadByteAbsolute: UInt16  = 0x30   // BPF_LD|BPF_B|BPF_ABS
    public static let loadHalfAbsolute: UInt16  = 0x28   // BPF_LD|BPF_H|BPF_ABS
    public static let loadWordAbsolute: UInt16  = 0x20   // BPF_LD|BPF_W|BPF_ABS
    // ALU
    public static let andConstant: UInt16       = 0x54   // BPF_ALU|BPF_AND|BPF_K
    // Jumps
    public static let jumpAlways: UInt16        = 0x05   // BPF_JMP|BPF_JA|BPF_K
    public static let jumpEqualConstant: UInt16 = 0x15   // BPF_JMP|BPF_JEQ|BPF_K
    // Return
    public static let returnConstant: UInt16    = 0x06   // BPF_RET|BPF_K
}

/// A step in a filter, before jump targets have been resolved to offsets.
///
/// Jump offsets in BPF are counted from the instruction *after* the jump, and
/// getting one wrong does not fail -- it silently captures the wrong traffic.
/// So targets are written as labels here and the offsets are computed, rather
/// than counted by hand.
public enum BPFStep {
    case label(String)
    case loadByte(offset: UInt32)
    case loadHalf(offset: UInt32)
    case loadWord(offset: UInt32)
    case and(UInt32)
    /// Jump to `ifEqual` when the accumulator equals `value`, otherwise to
    /// `otherwise`. A nil target means "fall through to the next instruction".
    case jumpEqual(UInt32, ifEqual: String?, otherwise: String?)
    case jump(String)
    case returnConstant(UInt32)
}

public enum BPFAssemblyError: Error, Equatable, CustomStringConvertible {
    case unknownLabel(String)
    case jumpTooFar(String)
    case backwardJump(String)

    public var description: String {
        switch self {
        case .unknownLabel(let name): return "no such label: \(name)"
        case .jumpTooFar(let name):   return "jump to \(name) exceeds the 255-instruction reach of a conditional jump"
        case .backwardJump(let name): return "backward jump to \(name); classic BPF is forward-only"
        }
    }
}

public enum BPFAssembler {
    public static func assemble(_ steps: [BPFStep]) throws -> [BPFInstruction] {
        // First pass: where does each label land once labels are removed?
        var labelPositions: [String: Int] = [:]
        var position = 0
        for step in steps {
            if case .label(let name) = step {
                labelPositions[name] = position
            } else {
                position += 1
            }
        }
        let totalCount = position

        // Second pass: emit, resolving each target to an offset counted from
        // the instruction after the jump.
        var instructions: [BPFInstruction] = []
        instructions.reserveCapacity(totalCount)

        func offset(to label: String?, from index: Int) throws -> UInt8 {
            guard let label else { return 0 }           // fall through
            guard let target = labelPositions[label] else { throw BPFAssemblyError.unknownLabel(label) }
            let delta = target - (index + 1)
            guard delta >= 0 else { throw BPFAssemblyError.backwardJump(label) }
            guard delta <= 255 else { throw BPFAssemblyError.jumpTooFar(label) }
            return UInt8(delta)
        }

        var index = 0
        for step in steps {
            switch step {
            case .label:
                continue
            case .loadByte(let value):
                instructions.append(BPFInstruction(code: BPFOpcode.loadByteAbsolute, k: value))
            case .loadHalf(let value):
                instructions.append(BPFInstruction(code: BPFOpcode.loadHalfAbsolute, k: value))
            case .loadWord(let value):
                instructions.append(BPFInstruction(code: BPFOpcode.loadWordAbsolute, k: value))
            case .and(let mask):
                instructions.append(BPFInstruction(code: BPFOpcode.andConstant, k: mask))
            case .jumpEqual(let value, let ifEqual, let otherwise):
                instructions.append(BPFInstruction(code: BPFOpcode.jumpEqualConstant,
                                                   jt: try offset(to: ifEqual, from: index),
                                                   jf: try offset(to: otherwise, from: index),
                                                   k: value))
            case .jump(let label):
                // BPF_JA uses k as the offset, and k is 32-bit, so it has reach
                // that a conditional jump does not.
                guard let target = labelPositions[label] else { throw BPFAssemblyError.unknownLabel(label) }
                let delta = target - (index + 1)
                guard delta >= 0 else { throw BPFAssemblyError.backwardJump(label) }
                instructions.append(BPFInstruction(code: BPFOpcode.jumpAlways, k: UInt32(delta)))
            case .returnConstant(let value):
                instructions.append(BPFInstruction(code: BPFOpcode.returnConstant, k: value))
            }
            index += 1
        }
        return instructions
    }
}

public enum MulticastFilter {
    /// Accepts IPv4 frames whose destination address is in 224.0.0.0/4,
    /// looking through up to two VLAN tags.
    ///
    /// Filtering in the kernel is the whole point on a mirrored uplink: most
    /// frames there are unicast, and copying them into userspace only to throw
    /// them away is the bulk of the cost.
    ///
    /// The destination address is matched rather than the destination MAC,
    /// because the IPv4-to-MAC mapping is lossy and a MAC match would also
    /// admit frames whose IP destination is not multicast at all.
    public static func steps(snapshotLength: UInt32) -> [BPFStep] {
        var steps: [BPFStep] = []

        // Untagged: EtherType at 12, IP header at 14, destination at 14 + 16.
        steps.append(.loadHalf(offset: 12))
        steps.append(.jumpEqual(0x0800, ifEqual: "ip0", otherwise: nil))
        steps.append(.jumpEqual(0x8100, ifEqual: "tag1", otherwise: nil))
        steps.append(.jumpEqual(0x88A8, ifEqual: "tag1", otherwise: nil))
        steps.append(.jumpEqual(0x9100, ifEqual: "tag1", otherwise: "reject"))

        steps.append(.label("ip0"))
        steps.append(.loadWord(offset: 30))
        steps.append(.jump("classify"))

        // One tag: EtherType at 16, IP header at 18, destination at 18 + 16.
        steps.append(.label("tag1"))
        steps.append(.loadHalf(offset: 16))
        steps.append(.jumpEqual(0x0800, ifEqual: "ip1", otherwise: nil))
        steps.append(.jumpEqual(0x8100, ifEqual: "tag2", otherwise: nil))
        steps.append(.jumpEqual(0x88A8, ifEqual: "tag2", otherwise: nil))
        steps.append(.jumpEqual(0x9100, ifEqual: "tag2", otherwise: "reject"))

        steps.append(.label("ip1"))
        steps.append(.loadWord(offset: 34))
        steps.append(.jump("classify"))

        // Two tags: EtherType at 20, IP header at 22, destination at 22 + 16.
        steps.append(.label("tag2"))
        steps.append(.loadHalf(offset: 20))
        steps.append(.jumpEqual(0x0800, ifEqual: "ip2", otherwise: "reject"))

        steps.append(.label("ip2"))
        steps.append(.loadWord(offset: 38))

        steps.append(.label("classify"))
        steps.append(.and(0xF000_0000))
        steps.append(.jumpEqual(0xE000_0000, ifEqual: "accept", otherwise: "reject"))

        steps.append(.label("accept"))
        steps.append(.returnConstant(snapshotLength))
        steps.append(.label("reject"))
        steps.append(.returnConstant(0))

        return steps
    }

    public static func program(snapshotLength: UInt32) throws -> [BPFInstruction] {
        try BPFAssembler.assemble(steps(snapshotLength: snapshotLength))
    }
}
