# Advanced VPS deployment

These scripts configure an Ubuntu/Debian VPS you administer. The control service
has no login or room access control. Keep it behind an access-controlled VPN or
protected tunnel. This is not a production security solution.

Prerequisites: Node.js 22+, npm, nginx, and a trusted TLS certificate for the
server IP at `/etc/letsencrypt/live/YOUR_IP/{fullchain,privkey}.pem`. Certificate
issuance and renewal are your responsibility. Prerequisites are checked before
changing services.

From the repository root, with your own server and a trusted SSH host key:

```sh
MEETING_PUBLIC_IP=203.0.113.10 \
MEETING_SSH_TARGET=root@203.0.113.10 \
MEETING_SSH_KEY="$HOME/.ssh/id_ed25519" \
./scripts/deploy-public-server.sh
```

Replace the documentation-only IP. An explicit IP is mandatory. The installer
creates a service account, random credentials under `/etc/meeting`, two services,
nginx configuration and UDP buffer settings. Inspect it before use on an existing
server. It downloads the LiveKit installer; pin/audit that dependency for your deployment.

The control service binds **127.0.0.1**. Reach port 9000 through a protected tunnel.
For a private VPN interface, set MEETING_HOST in `/etc/meeting/control.env` to that
VPN IP and restart `meeting-control-public`. Do not expose unauthenticated TCP
9000 to the public internet.

| Port | Purpose |
| --- | --- |
| TCP 7880 | nginx TLS / LiveKit WebSocket |
| TCP 7881, UDP 7882 | WebRTC media |
| TCP 7883 | Internal LiveKit HTTP, keep private |
| TCP/UDP 9000 | Loopback control / legacy diagnostics, keep private |

Firewall rules, TURN, identity management and certificate issuance are not
configured by these scripts. Existing VPN services are not changed.
