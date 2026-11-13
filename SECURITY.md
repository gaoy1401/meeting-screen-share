# Security model

This preview is for trusted LANs or access-controlled VPNs.

- Port 9000 uses plaintext TCP and does not authenticate room joins. Room IDs
  are not passwords; tokens travel on this connection.
- LiveKit/WebRTC transport encryption is not application-level E2EE. Trust the SFU.
- Legacy UDP media is unencrypted and only for diagnostics.
- TURN, user authentication, room authorization and global abuse limits are
  not implemented. UDP relay limits do not limit LiveKit room membership.
- Keep API secrets on the server. The optional hardware publisher is a trusted
  server component, not an untrusted client.
- Never publish `.runtime/`, `.env`, private keys, certificates or logs with
  tokens. Rotate real credentials that were accidentally shared.

Use sanitized Issues for ordinary bugs. For sensitive findings, use Security →
Report a vulnerability when private reporting is enabled. Otherwise request a
private contact in an issue without posting secrets or exploit details.
