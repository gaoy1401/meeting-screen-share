export const MAGIC = "MSH1";
export const VERSION = 1;
export const HEADER_SIZE = 32;
export const MAX_DATAGRAM_SIZE = 1200;
export const MAX_PAYLOAD_SIZE = MAX_DATAGRAM_SIZE - HEADER_SIZE;
export const RTP_HEADER_SIZE = 12;
export const RTP_MAX_PAYLOAD_SIZE = MAX_DATAGRAM_SIZE - RTP_HEADER_SIZE;
export const RTPPayloadType = Object.freeze({
  H264: 96,
  OPUS: 111
});

export const PacketType = Object.freeze({
  CONTROL: 1,
  AUDIO: 2,
  SCREEN: 3
});

const validTypes = new Set(Object.values(PacketType));
const validRTPPayloadTypes = new Set(Object.values(RTPPayloadType));

export function isControlDatagram(data) {
  return Buffer.isBuffer(data) &&
    data.length >= 4 &&
    data.toString("ascii", 0, 4) === MAGIC;
}

export function parseRTPPacket(data) {
  if (!Buffer.isBuffer(data) || data.length < RTP_HEADER_SIZE) {
    throw new Error("RTP packet is shorter than the fixed header");
  }
  if (data.length > MAX_DATAGRAM_SIZE) {
    throw new Error("RTP packet exceeds the maximum datagram size");
  }
  if ((data.readUInt8(0) >> 6) !== 2) {
    throw new Error("unsupported RTP version");
  }
  const hasPadding = (data.readUInt8(0) & 0x20) !== 0;
  const hasExtension = (data.readUInt8(0) & 0x10) !== 0;
  const csrcCount = data.readUInt8(0) & 0x0F;
  if (hasPadding || hasExtension || csrcCount !== 0) {
    throw new Error("unsupported RTP header");
  }
  const payloadType = data.readUInt8(1) & 0x7F;
  if (!validRTPPayloadTypes.has(payloadType)) {
    throw new Error("unknown RTP payload type");
  }
  return {
    marker: (data.readUInt8(1) & 0x80) !== 0,
    payloadType,
    sequence: data.readUInt16BE(2),
    timestamp: data.readUInt32BE(4),
    ssrc: data.readUInt32BE(8),
    payload: data.subarray(RTP_HEADER_SIZE)
  };
}

export function buildRTPPacket({
  marker = false,
  payloadType,
  sequence,
  timestamp,
  ssrc,
  payload = Buffer.alloc(0)
}) {
  if (!validRTPPayloadTypes.has(payloadType)) {
    throw new Error("unknown RTP payload type");
  }
  if (!Buffer.isBuffer(payload)) payload = Buffer.from(payload);
  if (payload.length > RTP_MAX_PAYLOAD_SIZE) {
    throw new Error("RTP payload exceeds the maximum size");
  }
  const data = Buffer.allocUnsafe(RTP_HEADER_SIZE + payload.length);
  data.writeUInt8(0x80, 0);
  data.writeUInt8((marker ? 0x80 : 0) | payloadType, 1);
  data.writeUInt16BE(sequence & 0xFFFF, 2);
  data.writeUInt32BE(timestamp >>> 0, 4);
  data.writeUInt32BE(ssrc >>> 0, 8);
  payload.copy(data, RTP_HEADER_SIZE);
  return data;
}

export function parsePacket(data) {
  if (!Buffer.isBuffer(data) || data.length < HEADER_SIZE) {
    throw new Error("packet is shorter than the fixed header");
  }
  if (data.length > MAX_DATAGRAM_SIZE) {
    throw new Error("packet exceeds the maximum datagram size");
  }
  if (data.toString("ascii", 0, 4) !== MAGIC) {
    throw new Error("invalid packet magic");
  }
  if (data.readUInt8(4) !== VERSION) {
    throw new Error("unsupported protocol version");
  }

  const type = data.readUInt8(5);
  if (!validTypes.has(type)) {
    throw new Error("unknown packet type");
  }

  const packet = {
    type,
    flags: data.readUInt16BE(6),
    sessionId: data.readUInt32BE(8),
    sequence: data.readUInt32BE(12),
    frameId: data.readUInt32BE(16),
    chunkIndex: data.readUInt16BE(20),
    chunkCount: data.readUInt16BE(22),
    timestampMs: data.readBigUInt64BE(24),
    payload: data.subarray(HEADER_SIZE)
  };

  if (type === PacketType.SCREEN) {
    if (packet.chunkCount === 0 || packet.chunkIndex >= packet.chunkCount) {
      throw new Error("invalid screen chunk metadata");
    }
  }

  return packet;
}

export function buildPacket({
  type,
  flags = 0,
  sessionId,
  sequence = 0,
  frameId = 0,
  chunkIndex = 0,
  chunkCount = 0,
  timestampMs = BigInt(Date.now()),
  payload = Buffer.alloc(0)
}) {
  if (!validTypes.has(type)) throw new Error("unknown packet type");
  if (!Buffer.isBuffer(payload)) payload = Buffer.from(payload);
  if (payload.length > MAX_PAYLOAD_SIZE) {
    throw new Error("payload exceeds the maximum size");
  }

  const data = Buffer.allocUnsafe(HEADER_SIZE + payload.length);
  data.write(MAGIC, 0, 4, "ascii");
  data.writeUInt8(VERSION, 4);
  data.writeUInt8(type, 5);
  data.writeUInt16BE(flags, 6);
  data.writeUInt32BE(sessionId >>> 0, 8);
  data.writeUInt32BE(sequence >>> 0, 12);
  data.writeUInt32BE(frameId >>> 0, 16);
  data.writeUInt16BE(chunkIndex, 20);
  data.writeUInt16BE(chunkCount, 22);
  data.writeBigUInt64BE(BigInt(timestampMs), 24);
  payload.copy(data, HEADER_SIZE);
  return data;
}

export function buildControlPacket(sessionId, sequence, body) {
  return buildPacket({
    type: PacketType.CONTROL,
    sessionId,
    sequence,
    payload: Buffer.from(JSON.stringify(body), "utf8")
  });
}

export function parseControlPayload(payload) {
  if (payload.length === 0 || payload.length > MAX_PAYLOAD_SIZE) {
    throw new Error("invalid control payload size");
  }
  let value;
  try {
    value = JSON.parse(payload.toString("utf8"));
  } catch {
    throw new Error("control payload is not valid JSON");
  }
  if (value === null || Array.isArray(value) || typeof value !== "object") {
    throw new Error("control payload must be an object");
  }
  return value;
}
