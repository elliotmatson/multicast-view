// swift-tools-version:5.8
import PackageDescription

let package = Package(
    name: "MulticastView",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "MulticastView", targets: ["MulticastView"]),
        .library(name: "MulticastCore", targets: ["MulticastCore"]),
    ],
    targets: [
        // Pure logic. Parsing, classification, aggregation, SNMP encoding.
        // No syscalls, no capture, no network -- unit testable anywhere.
        .target(name: "MulticastCore"),

        // C shim for BPF. ioctl is C-variadic and the BIOC* request codes are
        // function-like macros; neither imports into Swift.
        .target(name: "CBPF"),

        // Everything that touches the kernel: BPF capture, getifmaddrs,
        // interface enumeration, SNMP UDP transport.
        .target(name: "MulticastSystem", dependencies: ["MulticastCore", "CBPF"]),

        .executableTarget(name: "MulticastView", dependencies: ["MulticastCore", "MulticastSystem"]),

        .testTarget(name: "MulticastCoreTests", dependencies: ["MulticastCore"]),
    ]
)
