import { loadConfig } from "./config.js";
import { createLiveKitTokenIssuer } from "./livekit-token.js";
import { MeetingServer } from "./meeting-server.js";
import { SignalingServer } from "./signaling-server.js";

const config = loadConfig();
const signaling = new SignalingServer(config, {
  issueWebRTCToken: createLiveKitTokenIssuer(config)
});
const server = new MeetingServer(config, undefined, {
  authorizeJoin: (context) => signaling.authorizeUDPJoin(context)
});

server.on("error", (error) => {
  console.error("[udp] server error:", error);
});
signaling.on("error", (error) => {
  console.error("[tcp] signaling error:", error);
});
signaling.on("leaveSession", (sessionId) => {
  server.removeSession(sessionId);
});
server.on("joined", ({ room, name, address, port }) => {
  console.log(`[room:${room}] ${name} joined from ${address}:${port}`);
});
server.on("joined", (member) => signaling.confirmJoined(member));
server.on("snapshot", ({ room, participants }) => {
  signaling.broadcastSnapshot(room, participants);
});
server.on("left", ({ room, name }) => {
  console.log(`[room:${room}] ${name} left`);
});
server.on("timedOut", ({ room, name }) => {
  console.log(`[room:${room}] ${name} timed out`);
});

if (process.env.MEETING_LOG_MEDIA === "1") {
  const mediaTotals = new Map();
  server.on("media", ({ room, name, type, bytes, peerCount }) => {
    const key = `${room}\t${name}\t${type}`;
    const current = mediaTotals.get(key) ?? { packets: 0, bytes: 0, peerCount: 0 };
    current.packets += 1;
    current.bytes += bytes;
    current.peerCount = peerCount;
    mediaTotals.set(key, current);
  });
  const mediaTimer = setInterval(() => {
    for (const [key, total] of mediaTotals) {
      const [room, name, type] = key.split("\t");
      const label =
        type === "111" ? "audio/opus" :
        type === "96" ? "screen/h264" :
        type === "2" ? "legacy-audio" :
        type === "3" ? "legacy-screen" :
        type;
      console.log(
        `[media:${room}] ${name} ${label}: ${total.packets} packets, ` +
        `${total.bytes} bytes, ${total.peerCount} peers`
      );
    }
    mediaTotals.clear();
  }, 5000);
  mediaTimer.unref();
}

const [udpAddress, tcpAddress] = await Promise.all([
  server.start(),
  signaling.start()
]);
console.log(`Meeting UDP media listening on ${udpAddress.address}:${udpAddress.port}`);
console.log(`Meeting TCP signaling listening on ${tcpAddress.address}:${tcpAddress.port}`);
console.log(`Meeting WebRTC SFU endpoint: ${config.livekitUrl}`);

async function shutdown(signal) {
  console.log(`\nReceived ${signal}; shutting down.`);
  await Promise.all([server.stop(), signaling.stop()]);
  process.exit(0);
}

process.on("SIGINT", () => shutdown("SIGINT"));
process.on("SIGTERM", () => shutdown("SIGTERM"));
