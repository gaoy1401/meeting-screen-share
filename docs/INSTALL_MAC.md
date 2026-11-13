# Install Meeting Client on macOS

Requirements: macOS 13 or later, Apple Silicon for the `arm64` archive, or an
Intel Mac for an `x86_64` archive. Download only the architecture you use.

1. Verify the ZIP against its `.sha256` file (`shasum -a 256 -c FILE.zip.sha256`).
2. Unzip it and drag `MeetingClient.app` to Applications.
3. Open the app. This preview is ad-hoc signed, **not Apple notarized**. If macOS
   blocks it, use System Settings → Privacy & Security → Open Anyway only after
   checking the source. Do not disable Gatekeeper globally.
4. Enter the address of **your own** meeting server, for example
   `192.168.1.10:9000`, and use the same room ID as the other participant.
5. Grant microphone and screen-recording permission when you choose to use
   those features. Select a display or window before starting screen sharing.

The app does not include a hosted meeting service. `127.0.0.1:9000` works only
when the server is running on the same Mac. See the repository README for setup.
Use headphones for a two-device audio test. A successful room join alone does
not prove that the other device can see the screen or hear audio.

Uninstall by deleting the app from Applications. Server processes started with
`mac-server/bin/start.sh` are separate: stop them with `mac-server/bin/stop.sh`.
