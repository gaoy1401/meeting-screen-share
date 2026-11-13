# LiveKit C++ SDK 1.4.0 license supplement

The official `livekit-sdk-windows-x64-1.4.0.zip` release builds successfully but
contains no LICENSE or NOTICE files. The Windows packaging script includes the
unmodified files from the matching upstream v1.4.0 tag:

- LICENSE: https://github.com/livekit/client-sdk-cpp/blob/v1.4.0/LICENSE
  (Git blob `67db8588217f266eb561f75fae738656325deac9`).
- NOTICE: https://github.com/livekit/client-sdk-cpp/blob/v1.4.0/NOTICE
  (Git blob `692adc99215eab510e2f4617a132cdcdb5cda026`).

The binary archive is pinned by SHA-256 in
`windows-client/cmake/LiveKitSDK.cmake`. Review these supplements when upgrading
the SDK. Any notices present in the downloaded SDK are also retained.
