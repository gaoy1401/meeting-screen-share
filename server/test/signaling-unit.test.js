import assert from "node:assert/strict";
import { EventEmitter } from "node:events";
import test from "node:test";
import { SignalingServer } from "../src/signaling-server.js";

class TestSocket extends EventEmitter {
  destroyed = false;
  messages = [];
  setEncoding() {}
  setKeepAlive() {}
  setNoDelay() {}
  write(line) { this.messages.push(JSON.parse(line)); }
  destroy() { this.destroyed = true; this.emit("close"); }
  end() { this.destroy(); }
}

function connect(issuer) {
  const signaling = new SignalingServer({}, { issueWebRTCToken: issuer });
  const socket = new TestSocket();
  signaling.server.emit("connection", socket);
  return { signaling, socket, client: [...signaling.clients][0] };
}

const join = (room, sessionId) => JSON.stringify({
  action: "join", room, sessionId, name: "Alice", transport: "webrtc"
}) + "\n";

test("overlapping joins keep the signed token and room paired in request order", async () => {
  let releaseFirst;
  const first = new Promise((resolve) => { releaseFirst = resolve; });
  const { signaling, socket, client } = connect(async ({ room }) => {
    if (room === "first") await first;
    return { url: "ws://localhost:7880", token: `token-for-${room}` };
  });
  socket.emit("data", join("first", 1) + join("second", 2));
  releaseFirst();
  await client.queue;
  assert.deepEqual(socket.messages.map(({ room, token }) => [room, token]), [
    ["first", "token-for-first"], ["second", "token-for-second"]
  ]);
  await signaling.stop();
});

test("a closed connection cannot be marked joined when signing finishes", async () => {
  let finish;
  const signed = new Promise((resolve) => { finish = resolve; });
  const { signaling, socket, client } = connect(() => signed);
  socket.emit("data", join("demo", 1));
  await Promise.resolve();
  socket.destroy();
  finish({ url: "ws://localhost:7880", token: "test-token" });
  await client.queue;
  assert.equal(client.joined, false);
  assert.equal(socket.messages.length, 0);
  assert.equal(signaling.clients.size, 0);
});

test("coalesced valid lines may exceed one line limit in total", async () => {
  const { signaling, socket, client } = connect();
  const line = JSON.stringify({ action: "heartbeat", padding: "x".repeat(2200) }) + "\n";
  socket.emit("data", line + line);
  await client.queue;
  assert.equal(socket.destroyed, false);
  assert.equal(socket.messages.length, 2);
  socket.emit("data", "x".repeat(4097));
  assert.equal(socket.destroyed, true);
  await signaling.stop();
});
