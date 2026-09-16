import Foundation
import Darwin
import CBPF
import MulticastCore

public enum CaptureError: Error, LocalizedError {
    /// Every /dev/bpf* refused us. This is the ChmodBPF case and deserves its
    /// own message, not the generic one.
    case permissionDenied
    case noDeviceAvailable(attempts: Int)
    case openFailed(errno: Int32)
    case configurationFailed(step: String, errno: Int32)
    case unsupportedDataLink(UInt32)
    case alreadyRunning

    public var errorDescription: String? {
        switch self {
        case .permissionDenied:
            return "No permission to open a packet capture device"
        case .noDeviceAvailable(let attempts):
            return "All \(attempts) packet capture devices are in use"
        case .openFailed(let code):
            return "Could not open a capture device: \(String(cString: strerror(code)))"
        case .configurationFailed(let step, let code):
            return "Capture setup failed at \(step): \(String(cString: strerror(code)))"
        case .unsupportedDataLink(let type):
            return "This interface reports data link type \(type); only Ethernet is supported"
        case .alreadyRunning:
            return "Capture is already running"
        }
    }

    /// The bit that tells you what to actually do about it.
    public var recoverySuggestion: String? {
        switch self {
        case .permissionDenied:
            return "macOS restricts /dev/bpf* to the access_bpf group. Wireshark's ChmodBPF helper "
                 + "creates that group and adds you to it. Install Wireshark and run "
                 + "\"Install ChmodBPF\" from its installer, or from "
                 + "/Applications/Wireshark.app/Contents/Resources/Extras, then log out and back in.\n\n"
                 + "MulticastView is unsigned and deliberately has no privileged helper of its own: "
                 + "shipping one would need a paid Developer ID."
        case .noDeviceAvailable:
            return "Another capture is holding every BPF device. Quit Wireshark, tcpdump or any "
                 + "other capture tool and try again."
        case .unsupportedDataLink:
            return "Pick a wired or Wi-Fi interface rather than a tunnel or virtual interface."
        default:
            return nil
        }
    }
}

public struct CaptureStatistics: Equatable {
    /// Packets the filter accepted.
    public let received: UInt32
    /// Packets the kernel had to throw away because the buffer was full.
    /// Any drops at all mean every rate shown is understated.
    public let dropped: UInt32

    public var dropFraction: Double {
        let total = Double(received) + Double(dropped)
        return total > 0 ? Double(dropped) / total : 0
    }
}

public final class BPFCapture {
    public struct Configuration {
        public var interfaceName: String
        /// The kernel buffer. Bigger means fewer drops on a busy mirror port.
        public var bufferBytes: Int
        public var snapshotLength: Int
        /// Process one packet in every `sampleRate`. Counts are scaled back up.
        public var sampleRate: Int
        public var promiscuous: Bool
        /// Include packets this host itself sent. On by default, matching
        /// tcpdump and Wireshark -- and what this host sends really is on the
        /// wire, so excluding it would understate the totals. It also lets the
        /// traffic generator in Scripts/ exercise the app from one machine.
        public var seeSent: Bool

        public init(interfaceName: String, bufferBytes: Int = 4 * 1024 * 1024,
                    snapshotLength: Int = 256, sampleRate: Int = 1,
                    promiscuous: Bool = true, seeSent: Bool = true) {
            self.interfaceName = interfaceName
            self.bufferBytes = bufferBytes
            self.snapshotLength = snapshotLength
            self.sampleRate = max(1, sampleRate)
            self.promiscuous = promiscuous
            self.seeSent = seeSent
        }
    }

    private var fileDescriptor: Int32 = -1
    private var readBufferLength: Int = 0
    private var thread: Thread?
    private let running = AtomicFlag()
    private let parser: PacketParser
    private var sampleCounter = 0
    private var clockOffset: Double = 0
    private var clockOffsetResolved = false

    public private(set) var configuration: Configuration
    public private(set) var deviceName: String = ""

    public init(configuration: Configuration, parser: PacketParser = PacketParser()) {
        self.configuration = configuration
        self.parser = parser
    }

    deinit { stop() }

    /// Checks whether a BPF device can be opened at all, without binding an
    /// interface. Used to show the ChmodBPF explanation before the user has
    /// even pressed Start.
    public static func probePermissions() -> Result<String, CaptureError> {
        let result = mcv_bpf_open(64)
        if result.fd >= 0 {
            let name = withUnsafePointer(to: result.device) {
                $0.withMemoryRebound(to: CChar.self, capacity: 32) { String(cString: $0) }
            }
            mcv_bpf_close(result.fd)
            return .success(name)
        }
        if result.permission_denied != 0 { return .failure(.permissionDenied) }
        if result.last_errno == EBUSY { return .failure(.noDeviceAvailable(attempts: Int(result.attempts))) }
        return .failure(.openFailed(errno: result.last_errno))
    }

    /// `onPackets` is called **on the capture thread**, once per read(2), and
    /// must be cheap and thread-safe. It is deliberately not hopped to the main
    /// queue: immediate mode wakes the reader as soon as a single packet is
    /// available, which on a busy mirror is well over a thousand reads a
    /// second, and one main-queue block per read starves the UI. Aggregate on
    /// this thread behind a lock and let the UI read a snapshot on its own
    /// schedule instead.
    ///
    /// `onError` is delivered on the main queue, because it is rare and ends
    /// the capture.
    public func start(onPackets: @escaping ([ObservedPacket]) -> Void,
                      onError: @escaping (CaptureError) -> Void) throws {
        guard !running.value else { throw CaptureError.alreadyRunning }
        try open()

        running.value = true
        let thread = Thread { [weak self] in
            self?.readLoop(onPackets: onPackets, onError: onError)
        }
        thread.name = "MulticastView.capture"
        // The read blocks, so this gets its own Thread rather than a dispatch
        // queue -- a blocked read would tie up a queue's worker indefinitely.
        thread.stackSize = 512 * 1024
        self.thread = thread
        thread.start()
    }

    public func stop() {
        guard running.value else { return }
        running.value = false
        // The read timeout makes the blocking read return on its own, so the
        // loop notices this flag rather than being killed mid-read.
        thread = nil
    }

    public var isRunning: Bool { running.value }

    public func statistics() -> CaptureStatistics? {
        guard fileDescriptor >= 0 else { return nil }
        var received: UInt32 = 0
        var dropped: UInt32 = 0
        guard mcv_bpf_get_stats(fileDescriptor, &received, &dropped) == 0 else { return nil }
        return CaptureStatistics(received: received, dropped: dropped)
    }

    // MARK: - Setup

    private func open() throws {
        let opened = mcv_bpf_open(256)
        guard opened.fd >= 0 else {
            if opened.permission_denied != 0 { throw CaptureError.permissionDenied }
            if opened.last_errno == EBUSY {
                throw CaptureError.noDeviceAvailable(attempts: Int(opened.attempts))
            }
            throw CaptureError.openFailed(errno: opened.last_errno)
        }
        fileDescriptor = opened.fd
        deviceName = withUnsafePointer(to: opened.device) {
            $0.withMemoryRebound(to: CChar.self, capacity: 32) { String(cString: $0) }
        }

        do {
            // Buffer length MUST be set before the interface is bound; the
            // kernel refuses BIOCSBLEN once an interface is attached.
            try check(mcv_bpf_set_buffer_length(fileDescriptor, UInt32(configuration.bufferBytes)),
                      step: "set buffer length")

            try check(mcv_bpf_set_interface(fileDescriptor, configuration.interfaceName),
                      step: "bind interface \(configuration.interfaceName)")

            // Read back what the kernel actually settled on. Every read() has to
            // use exactly this size or it fails with EINVAL.
            var actual: UInt32 = 0
            try check(mcv_bpf_get_buffer_length(fileDescriptor, &actual), step: "read buffer length")
            readBufferLength = Int(actual)

            var dataLink: UInt32 = 0
            try check(mcv_bpf_get_datalink(fileDescriptor, &dataLink), step: "read data link type")
            guard dataLink == 1 else { throw CaptureError.unsupportedDataLink(dataLink) }

            // Without immediate mode the kernel waits for the buffer to fill, so
            // on a quiet VLAN packets arrive in bursts minutes apart and every
            // rate computed from them is wrong.
            try check(mcv_bpf_set_immediate(fileDescriptor, 1), step: "enable immediate mode")

            // Wake the blocking read periodically so stop() is noticed promptly.
            try check(mcv_bpf_set_read_timeout(fileDescriptor, 250), step: "set read timeout")

            _ = mcv_bpf_set_see_sent(fileDescriptor, configuration.seeSent ? 1 : 0)

            if configuration.promiscuous {
                // Without this a mirror port shows almost nothing, because none
                // of the mirrored frames are addressed to this host.
                try check(mcv_bpf_set_promiscuous(fileDescriptor), step: "enable promiscuous mode")
            }

            try installFilter()
        } catch {
            mcv_bpf_close(fileDescriptor)
            fileDescriptor = -1
            throw error
        }
    }

    private func installFilter() throws {
        let program = try MulticastFilter.program(snapshotLength: UInt32(configuration.snapshotLength))
        var instructions = program.map {
            mcv_bpf_insn(code: $0.code, jt: $0.jt, jf: $0.jf, k: $0.k)
        }
        let result = instructions.withUnsafeMutableBufferPointer { buffer -> Int32 in
            mcv_bpf_set_filter(fileDescriptor, buffer.baseAddress, UInt32(buffer.count))
        }
        try check(result, step: "install packet filter")
    }

    private func check(_ result: Int32, step: String) throws {
        guard result != 0 else { return }
        throw CaptureError.configurationFailed(step: step, errno: errno)
    }

    // MARK: - Read loop

    private func readLoop(onPackets: @escaping ([ObservedPacket]) -> Void,
                          onError: @escaping (CaptureError) -> Void) {
        let descriptor = fileDescriptor
        let bufferLength = readBufferLength
        guard descriptor >= 0, bufferLength > 0 else { return }

        let buffer = UnsafeMutableRawPointer.allocate(byteCount: bufferLength, alignment: 16)
        defer {
            buffer.deallocate()
            mcv_bpf_close(descriptor)
            if fileDescriptor == descriptor { fileDescriptor = -1 }
        }

        var batch: [ObservedPacket] = []
        batch.reserveCapacity(256)

        while running.value {
            // The read length must be exactly the buffer length the kernel
            // reported, or it fails with EINVAL.
            let bytesRead = read(descriptor, buffer, bufferLength)

            if bytesRead < 0 {
                let code = errno
                if code == EINTR || code == EAGAIN { continue }
                if code == ENXIO || code == ENETDOWN {
                    // The interface went away -- a Thunderbolt adapter unplugged.
                    DispatchQueue.main.async { onError(.configurationFailed(step: "read", errno: code)) }
                    return
                }
                DispatchQueue.main.async { onError(.configurationFailed(step: "read", errno: code)) }
                return
            }
            guard bytesRead > 0 else { continue }

            batch.removeAll(keepingCapacity: true)
            decode(buffer: buffer, length: bytesRead, into: &batch)

            if !batch.isEmpty {
                onPackets(batch)
            }
        }
    }

    /// Walks the packets in one read. A single read returns many packets, each
    /// behind a struct bpf_hdr and each padded out to a word boundary -- so the
    /// buffer is walked rather than assumed to hold one packet.
    private func decode(buffer: UnsafeMutableRawPointer, length: Int, into batch: inout [ObservedPacket]) {
        let whole = UnsafeRawBufferPointer(start: buffer, count: length)
        var offset = 0

        while offset < length {
            var payloadOffset = 0
            var capturedLength: UInt32 = 0
            var originalLength: UInt32 = 0
            var seconds: Int64 = 0
            var microseconds: Int32 = 0
            var nextOffset = 0

            let more = mcv_bpf_next_packet(buffer, length, offset,
                                           &payloadOffset, &capturedLength, &originalLength,
                                           &seconds, &microseconds, &nextOffset)
            guard more == 1, nextOffset > offset else { break }
            offset = nextOffset

            // Sampling: only every Nth packet is parsed. This does not reduce
            // the kernel-to-userspace copy, but it does cut the parsing and
            // aggregation cost, which is what lets the reader keep draining the
            // buffer fast enough to stop the kernel dropping packets.
            sampleCounter += 1
            if configuration.sampleRate > 1 && sampleCounter % configuration.sampleRate != 0 { continue }

            guard capturedLength > 0,
                  payloadOffset >= 0,
                  payloadOffset + Int(capturedLength) <= length else { continue }

            let timestamp = wallClock(seconds: seconds, microseconds: microseconds)
            let slice = UnsafeRawBufferPointer(rebasing: whole[payloadOffset..<(payloadOffset + Int(capturedLength))])

            if let packet = parser.parse(ByteCursor(slice), timestamp: timestamp) {
                batch.append(packet)
            }
        }
    }

    /// BPF timestamps have been gettimeofday-based and boot-relative at
    /// different times. Rather than trust either, the first packet establishes
    /// an offset against the wall clock, and it is applied to the rest. If the
    /// header is already wall-clock the offset is zero and nothing changes.
    private func wallClock(seconds: Int64, microseconds: Int32) -> Double {
        let raw = Double(seconds) + Double(microseconds) / 1_000_000
        if !clockOffsetResolved {
            clockOffsetResolved = true
            let now = Date().timeIntervalSince1970
            clockOffset = abs(now - raw) > 3600 ? now - raw : 0
        }
        return raw + clockOffset
    }
}

/// A flag readable from the capture thread and writable from the main thread.
final class AtomicFlag {
    private var storage = false
    private let lock = NSLock()

    var value: Bool {
        get { lock.lock(); defer { lock.unlock() }; return storage }
        set { lock.lock(); storage = newValue; lock.unlock() }
    }
}
