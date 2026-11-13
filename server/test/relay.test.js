import assert from "node:assert/strict";
import dgram from "node:dgram";
import test from "node:test";
import { MeetingServer } from "../src/meeting-server.js";
import {
  PacketType,
  RTPPayloadType,
  buildControlPacket,
  buildPacket,
  buildRTPPacket,
  isControlDatagram,
  parseControlPayload,
  parsePacket,
  parseRTPPacket
} from "../src/protocol.js";

const config = {
  host: "127.0.0.1",
  port: 0,
  maxParticipantsPerRoom: 8,
  memberTimeoutMs: 15_000,
  bytesPerSecond: 6_000_000,
  burstBytes: 12_000_000
};

function createClient(serverPort, sessionId) {
  const socket = dgram.createSocket("udp4");
  const inbox = [];
  const waiters = [];

  socket.on("message", (data) => {
    const packet = isControlDatagram(data) ? parsePacket(data) : parseRTPPacket(data);
    const waiterIndex = waiters.findIndex((waiter) => waiter.predicate(packet));
    if (waiterIndex >= 0) {
      const [waiter] = waiters.splice(waiterIndex, 1);
      clearTimeout(waiter.timer);
      waiter.resolve(packet);
    } else {
      inbox.push(packet);
    }
  });

  const send = (data) =>
    new Promise((resolve, reject) =>
      socket.send(data, serverPort, "127.0.0.1", (error) =>
        error ? reject(error) : resolve()
      )
    );

  return {
    socket,
    sessionId,
    send,
    join: (room, name) =>
      send(buildControlPacket(sessionId, 1, { action: "join", room, name })),
    waitFor(predicate, timeoutMs = 1000) {
      const existingIndex = inbox.findIndex(predicate);
      if (existingIndex >= 0) return Promise.resolve(inbox.splice(existingIndex, 1)[0]);
      return new Promise((resolve, reject) => {
        const waiter = { predicate, resolve, reject, timer: null };
        waiter.timer = setTimeout(() => {
          const index = waiters.indexOf(waiter);
          if (index >= 0) waiters.splice(index, 1);
          reject(new Error("timed out waiting for UDP packet"));
        }, timeoutMs);
        waiters.push(waiter);
      });
    },
    close: () => new Promise((resolve) => socket.close(resolve))
  };
}

const isControlAction = (action) => (packet) =>
  packet.type === PacketType.CONTROL &&
  parseControlPayload(packet.payload).action === action;

test("media reaches peers in the same room but not another room", async (t) => {
  const server = new MeetingServer(config);
  const address = await server.start();
  const alice = createClient(address.port, 101);
  const bob = createClient(address.port, 202);
  const outsider = createClient(address.port, 303);

  t.after(async () => {
    await Promise.all([alice.close(), bob.close(), outsider.close()]);
    await server.stop();
  });

  await alice.join("demo", "Alice");
  await alice.waitFor(isControlAction("joined"));
  await bob.join("demo", "Bob");
  await bob.waitFor(isControlAction("joined"));
  await outsider.join("other", "Mallory");
  await outsider.waitFor(isControlAction("joined"));

  const audio = buildPacket({
    type: PacketType.AUDIO,
    sessionId: alice.sessionId,
    sequence: 2,
    payload: Buffer.from([1, 2, 3, 4])
  });
  await alice.send(audio);

  const received = await bob.waitFor((packet) => packet.type === PacketType.AUDIO);
  assert.equal(received.sessionId, alice.sessionId);
  assert.deepEqual(received.payload, Buffer.from([1, 2, 3, 4]));

  await assert.rejects(
    outsider.waitFor((packet) => packet.type === PacketType.AUDIO, 100),
    /timed out/
  );
});

test("unjoined endpoints cannot inject media", async (t) => {
  const server = new MeetingServer(config);
  const address = await server.start();
  const alice = createClient(address.port, 111);
  const stranger = createClient(address.port, 999);

  t.after(async () => {
    await Promise.all([alice.close(), stranger.close()]);
    await server.stop();
  });

  await alice.join("demo", "Alice");
  await alice.waitFor(isControlAction("joined"));
  await stranger.send(
    buildPacket({
      type: PacketType.AUDIO,
      sessionId: stranger.sessionId,
      payload: Buffer.from("not allowed")
    })
  );

  await assert.rejects(
    alice.waitFor((packet) => packet.type === PacketType.AUDIO, 100),
    /timed out/
  );
});

test("RTP H264 media reaches peers in the same room", async (t) => {
  const server = new MeetingServer(config);
  const address = await server.start();
  const alice = createClient(address.port, 501);
  const bob = createClient(address.port, 502);

  t.after(async () => {
    await Promise.all([alice.close(), bob.close()]);
    await server.stop();
  });

  await alice.join("demo", "Alice");
  await alice.waitFor(isControlAction("joined"));
  await bob.join("demo", "Bob");
  await bob.waitFor(isControlAction("joined"));

  await alice.send(
    buildRTPPacket({
      marker: true,
      payloadType: RTPPayloadType.H264,
      sequence: 7,
      timestamp: 90_000,
      ssrc: alice.sessionId,
      payload: Buffer.from([0x65, 1, 2, 3])
    })
  );

  const received = await bob.waitFor(
    (packet) => packet.payloadType === RTPPayloadType.H264
  );
  assert.equal(received.ssrc, alice.sessionId);
  assert.equal(received.sequence, 7);
  assert.equal(received.timestamp, 90_000);
  assert.deepEqual(received.payload, Buffer.from([0x65, 1, 2, 3]));
});
