# User service examples

These templates assume a checkout at `~/meeting-screen-share`, a `.venv` under
it, Node.js at `/usr/bin/node`, and LiveKit at `~/.local/bin/livekit-server`.
Adjust paths for your installation.

1. Install dependencies and generate configuration with
   `python3 scripts/configure-server.py --ip YOUR_LAN_IPV4`.
2. Copy server units into `~/.config/systemd/user/`, run
   `systemctl --user daemon-reload`, then start the two server units.
3. Run the GTK client manually first. Its optional service needs
   `~/.config/meeting/client.env` containing DISPLAY and XAUTHORITY from your
   own X11 session, not another machine's UID or paths.
4. Import graphical session values with
   `systemctl --user import-environment DISPLAY XAUTHORITY DBUS_SESSION_BUS_ADDRESS`.

Automatic joining, microphone and external screen publishing are off in the
GTK example. The separate NVIDIA service starts screen capture immediately;
it requires X11, nvh264enc, LiveKit CLI and server credentials. Enable it only
when you intend to broadcast that desktop.
