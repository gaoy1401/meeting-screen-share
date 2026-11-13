// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "MeetingClient",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "MeetingClient", targets: ["MeetingClient"]),
        .executable(name: "MeetingCoreCheck", targets: ["MeetingCoreCheck"]),
        .executable(name: "MeetingMediaCheck", targets: ["MeetingMediaCheck"])
    ],
    dependencies: [
        .package(
            url: "https://github.com/livekit/client-sdk-swift.git",
            exact: "2.13.0"
        ),
        .package(
            url: "https://github.com/apple/swift-protobuf.git",
            exact: "1.31.2"
        )
    ],
    targets: [
        .target(name: "MeetingCore"),
        .target(
            name: "MeetingTransport",
            dependencies: ["MeetingCore"]
        ),
        .target(
            name: "MeetingMedia",
            dependencies: ["MeetingCore"]
        ),
        .target(
            name: "MeetingWebRTC",
            dependencies: [
                .product(name: "LiveKit", package: "client-sdk-swift")
            ]
        ),
        .executableTarget(
            name: "MeetingClient",
            dependencies: [
                "MeetingCore",
                "MeetingTransport",
                "MeetingMedia",
                "MeetingWebRTC"
            ]
        ),
        .executableTarget(
            name: "MeetingCoreCheck",
            dependencies: ["MeetingCore"]
        ),
        .executableTarget(
            name: "MeetingMediaCheck",
            dependencies: ["MeetingMedia"]
        )
    ]
)
