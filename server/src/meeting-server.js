import dgram from "node:dgram";
import { EventEmitter } from "node:events";
import {
  PacketType,
  buildControlPacket,
  isControlDatagram,
  parseControlPayload,
  parsePacket,
  parseRTPPacket
} from "./protocol.js";
import { endpointKey, RoomRegistry } from "./room-registry.js";
import { RateLimiter } from "./rate-limiter.js";

const ROOM_PATTERN = /^[A-Za-z0-9_-]{2,64}$/;

function normalizeName(value) {
  if (typeof value !== "string") throw new Error("name is required");
  const name = value.trim().slice(0, 32);
  if (name.length === 0) throw new Error("name is required");
  return name;
}

function normalizeRoom(value) {
  if (typeof value !== "string" || !ROOM_PATTERN.test(value)) {
    throw new Error("room must use 2-64 letters, numbers, underscores or hyphens");
  }
  return value;
}

export class MeetingServer extends EventEmitter {
  constructor(config, socket = dgram.createSocket("udp4"), options = {}) {
    super();
    this.config = config;
    this.socket = socket;
    this.rooms = new RoomRegistry(config);
    this.rateLimiter = new RateLimiter(config);
    this.serverSequence = 0;
    this.cleanupTimer = null;
    this.started = false;
    this.authorizeJoin = options.authorizeJoin ?? (() => true);
  }

  async start() {
    if (this.started) return this.socket.address();

    this.socket.on("message", (data, endpoint) => this.#onMessage(data, endpoint));
    this.socket.on("error", (error) => this.emit("error", error));

    await new Promise((resolve, reject) => {
      const onError = (error) => reject(error);
      this.socket.once("error", onError);
      this.socket.bind(this.config.port, this.config.host, () => {
        this.socket.off("error", onError);
        resolve();
      });
    });

    this.cleanupTimer = setInterval(
      () => this.#pruneMembers(),
      Math.max(1000, Math.floor(this.config.memberTimeoutMs / 3))
    );
    this.cleanupTimer.unref();
    this.started = true;
    return this.socket.address();
  }

  async stop() {
    if (this.cleanupTimer) clearInterval(this.cleanupTimer);
    this.cleanupTimer = null;
    if (!this.started) return;
    await new Promise((resolve) => this.socket.close(resolve));
    this.started = false;
  }

  removeSession(sessionId) {
    const member = this.rooms.getBySession(sessionId);
    if (member) this.#leave(member);
  }

  #onMessage(data, endpoint) {
    const key = endpointKey(endpoint);
    if (!this.rateLimiter.allow(key, data.length)) return;

    let packet;
    let sessionId;
    let mediaType;
    try {
      if (isControlDatagram(data)) {
        packet = parsePacket(data);
        if (packet.type === PacketType.CONTROL) {
          this.#handleControl(packet, endpoint);
          return;
        }
        sessionId = packet.sessionId;
        mediaType = packet.type;
      } else {
        packet = parseRTPPacket(data);
        sessionId = packet.ssrc;
        mediaType = packet.payloadType;
      }
    } catch (error) {
      this.emit("invalidPacket", { endpoint, error });
      return;
    }

    const member = this.rooms.touch(endpoint);
    if (!member || member.sessionId !== sessionId) return;
    const peers = this.rooms.peersOf(member);
    this.emit("media", {
      room: member.room,
      name: member.name,
      type: mediaType,
      bytes: data.length,
      peerCount: peers.length
    });
    for (const peer of peers) {
      this.socket.send(data, peer.port, peer.address);
    }
  }

  #handleControl(packet, endpoint) {
    let body;
    try {
      body = parseControlPayload(packet.payload);
      if (body.action === "join") {
        this.#join(packet, endpoint, body);
      } else if (body.action === "heartbeat") {
        const member = this.rooms.touch(endpoint);
        if (!member || member.sessionId !== packet.sessionId) {
          throw new Error("not joined");
        }
      } else if (body.action === "leave") {
        const member = this.rooms.get(endpoint);
        if (member?.sessionId === packet.sessionId) this.#leave(endpoint);
      } else {
        throw new Error("unknown control action");
      }
    } catch (error) {
      this.#sendControl(endpoint, packet.sessionId, {
        action: "error",
        message: error.message
      });
    }
  }

  #join(packet, endpoint, body) {
    const room = normalizeRoom(body.room);
    const name = normalizeName(body.name);
    if (!this.authorizeJoin({ body, packet, endpoint, room, name })) {
      throw new Error("UDP endpoint is not authorized by signaling");
    }
    const member = this.rooms.join(endpoint, {
      room,
      name,
      sessionId: packet.sessionId
    });

    this.#sendControl(member, member.sessionId, {
      action: "joined",
      room,
      sessionId: member.sessionId
    });
    this.emit("joined", member);
    this.#broadcastSnapshot(room);
  }

  #leave(endpoint) {
    const member = this.rooms.leave(endpoint);
    if (!member) return;
    this.rateLimiter.remove(member.key);
    this.#broadcastSnapshot(member.room);
    this.emit("left", member);
  }

  #pruneMembers() {
    const removed = this.rooms.prune();
    const affectedRooms = new Set();
    for (const member of removed) {
      this.rateLimiter.remove(member.key);
      affectedRooms.add(member.room);
      this.emit("timedOut", member);
    }
    for (const room of affectedRooms) this.#broadcastSnapshot(room);
  }

  #broadcastSnapshot(room) {
    const participants = this.rooms.participants(room);
    this.emit("snapshot", { room, participants });
    const members = this.rooms.rooms.get(room);
    if (!members) return;
    for (const member of members.values()) {
      this.#sendControl(member, member.sessionId, {
        action: "snapshot",
        participants
      });
    }
  }

  #sendControl(endpoint, sessionId, body) {
    const data = buildControlPacket(sessionId, this.serverSequence++, body);
    this.socket.send(data, endpoint.port, endpoint.address);
  }
}
