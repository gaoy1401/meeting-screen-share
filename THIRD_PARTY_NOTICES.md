# Third-party components

The MIT license covers this project's original code. Dependencies retain their
own licenses; they are not relicensed by this project. The binary packaging
scripts include the license and notice files found in the resolved dependencies.

| Component | Pinned version | Source |
| --- | --- | --- |
| LiveKit Swift SDK | 2.13.0 | https://github.com/livekit/client-sdk-swift |
| LiveKit WebRTC framework | 144.7559.3 | https://github.com/livekit/webrtc-xcframework |
| LiveKit UniFFI framework | 0.0.5 | https://github.com/livekit/livekit-uniffi-xcframework |
| SwiftProtobuf | 1.31.2 | https://github.com/apple/swift-protobuf |
| LiveKit C++ SDK | 1.4.0 | https://github.com/livekit/client-sdk-cpp |
| LiveKit Python SDK | 1.1.13 | https://github.com/livekit/python-sdks |
| LiveKit Node server SDK | 2.17.0 | https://github.com/livekit/node-sdks |

The Node lockfile additionally records @livekit/protocol, @bufbuild/protobuf and
jose. LiveKit Server, Python, GTK, GStreamer and operating-system frameworks
are installed separately and are not bundled with the macOS client. The Windows
installer also includes Microsoft's official Visual C++ Redistributable, whose
signature is verified during packaging and which retains Microsoft's license.

`patches/livekit-macos-dynamic-apps.patch` changes LiveKit's macOS capture filter
to include newly opened applications in full-display shares. The upstream SDK
license and notices are preserved with the packaged dependency licenses.

For redistribution of a custom build, inspect the actual bundled notices and
components, including WebRTC's third-party notices. Codec patent rights are
separate from source-code licenses. Do not remove upstream license files.

The pinned UniFFI 0.0.5 archive omitted a LICENSE file. The upstream license
supplement and provenance are included in `third-party/livekit-uniffi/`.
