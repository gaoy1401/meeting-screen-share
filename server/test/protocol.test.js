import assert from "node:assert/strict";
import test from "node:test";
import {
  MAX_PAYLOAD_SIZE,
  PacketType,
  RTPPayloadType,
  buildPacket,
  buildRTPPacket,
  parsePacket,
  parseRTPPacket
} from "../src/protocol.js";

test("binary packet round-trips all header fields", () => {
  const encoded = buildPacket({
    type: PacketType.SCREEN,
    flags: 7,
    sessionId: 0xfedcba98,
    sequence: 42,
    frameId: 11,
    chunkIndex: 2,
    chunkCount: 5,
    timestampMs: 123456789n,
    payload: Buffer.from("jpeg-fragment")
  });

  const decoded = parsePacket(encoded);
  assert.equal(decoded.type, PacketType.SCREEN);
  assert.equal(decoded.flags, 7);
  assert.equal(decoded.sessionId, 0xfedcba98);
  assert.equal(decoded.sequence, 42);
  assert.equal(decoded.frameId, 11);
  assert.equal(decoded.chunkIndex, 2);
  assert.equal(decoded.chunkCount, 5);
  assert.equal(decoded.timestampMs, 123456789n);
  assert.equal(decoded.payload.toString(), "jpeg-fragment");
});

test("oversized payloads are rejected", () => {
  assert.throws(
    () =>
      buildPacket({
        type: PacketType.AUDIO,
        sessionId: 1,
        payload: Buffer.alloc(MAX_PAYLOAD_SIZE + 1)
      }),
    /maximum size/
  );
});

test("RTP packets round-trip with standard fixed header fields", () => {
  const data = buildRTPPacket({
    marker: true,
    payloadType: RTPPayloadType.OPUS,
    sequence: 65530,
    timestamp: 123456,
    ssrc: 0xFEDCBA98,
    payload: Buffer.from([1, 2, 3])
  });
  const packet = parseRTPPacket(data);
  assert.equal(packet.marker, true);
  assert.equal(packet.payloadType, RTPPayloadType.OPUS);
  assert.equal(packet.sequence, 65530);
  assert.equal(packet.timestamp, 123456);
  assert.equal(packet.ssrc, 0xFEDCBA98);
  assert.deepEqual(packet.payload, Buffer.from([1, 2, 3]));
});
