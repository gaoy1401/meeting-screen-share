import assert from "node:assert/strict";
import dgram from "node:dgram";
import net from "node:net";
import test from "node:test";
import { MeetingServer } from "../src/meeting-server.js";
import { SignalingServer } from "../src/signaling-server.js";
import { buildControlPacket } from "../src/protocol.js";

const config = {
  host: "127.0.0.1",
  port: 0,
  maxParticipantsPerRoom: 8,
  memberTimeoutMs: 15_000,
  bytesPerSecond: 6_000_000,
  burstBytes: 12_000_000
};

function lineClient(port) {
  const socket = net.createConnection({ host: "127.0.0.1", port });
  const inbox = [];
  const waiters = [];
  let buffer = "";

  socket.setEncoding("utf8");
  socket.on("data", (chunk) => {
    buffer += chunk;
    let newline;
    while ((newline = buffer.indexOf("\n")) >= 0) {
      const body = JSON.parse(buffer.slice(0, newline));
      buffer = buffer.slice(newline + 1);
      const index = waiters.findIndex((waiter) => waiter.action === body.action);
      if (index >= 0) {
        const [waiter] = waiters.splice(index, 1);
        clearTimeout(waiter.timer);
        waiter.resolve(body);
      } else {
        inbox.push(body);
      }
    }
  });

  return {
    socket,
    ready: new Promise((resolve, reject) => {
      socket.once("connect", resolve);
      socket.once("error", reject);
    }),
    send(body) {
      socket.write(`${JSON.stringify(body)}\n`);
    },
    waitFor(action, timeoutMs = 1000) {
      const existing = inbox.findIndex((body) => body.action === action);
      if (existing >= 0) return Promise.resolve(inbox.splice(existing, 1)[0]);
      return new Promise((resolve, reject) => {
        const waiter = { action, resolve, timer: null };
        waiter.timer = setTimeout(() => {
          const index = waiters.indexOf(waiter);
          if (index >= 0) waiters.splice(index, 1);
          reject(new Error(`timed out waiting for ${action}`));
        }, timeoutMs);
        waiters.push(waiter);
      });
    }
  };
}

test("TCP signaling reliably authorizes and confirms a UDP media endpoint", async (t) => {
  const signaling = new SignalingServer(config);
  const meeting = new MeetingServer(config, undefined, {
    authorizeJoin: (context) => signaling.authorizeUDPJoin(context)
  });
  signaling.on("leaveSession", (sessionId) => meeting.removeSession(sessionId));
  meeting.on("joined", (member) => signaling.confirmJoined(member));
  meeting.on("snapshot", ({ room, participants }) => {
    signaling.broadcastSnapshot(room, participants);
  });

  const [udpAddress, tcpAddress] = await Promise.all([
    meeting.start(),
    signaling.start()
  ]);
  const tcp = lineClient(tcpAddress.port);
  const udp = dgram.createSocket("udp4");

  t.after(async () => {
    tcp.socket.destroy();
    await new Promise((resolve) => udp.close(resolve));
    await Promise.all([meeting.stop(), signaling.stop()]);
  });

  await tcp.ready;
  tcp.send({
    action: "join",
    room: "demo",
    name: "Alice",
    sessionId: 123
  });
  const bind = await tcp.waitFor("udp_bind");
  assert.equal(typeof bind.token, "string");

  await new Promise((resolve, reject) => {
    udp.send(
      buildControlPacket(123, 1, {
        action: "join",
        room: "demo",
        name: "Alice",
        token: bind.token
      }),
      udpAddress.port,
      "127.0.0.1",
      (error) => error ? reject(error) : resolve()
    );
  });

  const joined = await tcp.waitFor("joined");
  assert.equal(joined.room, "demo");
  assert.equal(joined.sessionId, 123);
  const snapshot = await tcp.waitFor("snapshot");
  assert.deepEqual(snapshot.participants, [{ sessionId: 123, name: "Alice" }]);
});

test("TCP signaling returns short-lived WebRTC credentials without UDP binding", async (t) => {
  const issued = [];
  const signaling = new SignalingServer(config, {
    issueWebRTCToken: async (join) => {
      issued.push(join);
      return {
        url: "ws://127.0.0.1:7880",
        token: "test-jwt"
      };
    }
  });
  const address = await signaling.start();
  const tcp = lineClient(address.port);

  t.after(async () => {
    tcp.socket.destroy();
    await signaling.stop();
  });

  await tcp.ready;
  tcp.send({
    action: "join",
    room: "demo",
    name: "Alice",
    sessionId: 456,
    transport: "webrtc"
  });

  const connect = await tcp.waitFor("webrtc_connect");
  assert.deepEqual(connect, {
    action: "webrtc_connect",
    url: "ws://127.0.0.1:7880",
    token: "test-jwt",
    room: "demo"
  });
  assert.deepEqual(issued, [{
    sessionId: 456,
    room: "demo",
    name: "Alice",
    transport: "webrtc"
  }]);
  assert.equal(signaling.members.size, 0);
  assert.equal(signaling.tokens.size, 0);
});
