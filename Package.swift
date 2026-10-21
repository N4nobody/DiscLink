// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "UDFDisc",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "udfdisc", targets: ["udfdisc"]),
        .executable(name: "UDFDiscApp", targets: ["UDFDiscApp"]),
    ],
    targets: [
        .target(
            name: "CMMC",
            linkerSettings: [.linkedFramework("IOKit"), .linkedFramework("CoreFoundation")]
        ),
        .target(name: "UDFKit", dependencies: ["CMMC"]),
        .executableTarget(name: "udfdisc", dependencies: ["UDFKit"]),
        .executableTarget(name: "UDFDiscApp", dependencies: ["UDFKit"]),
        // Unit tests as a plain executable: XCTest and Swift Testing need a full Xcode install.
        .executableTarget(name: "udfkit-tests", dependencies: ["UDFKit"], path: "Tests/UnitTests"),
    ]
)
