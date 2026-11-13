import crypto from "node:crypto";
import net from "node:net";
import { EventEmitter } from "node:events";

const ROOM_PATTERN = /^[A-Za-z0-9_-]{2,64}$/;
const MAX_LINE_BYTES = 4096;

function normalizeJoin(body) {
  const sessionId = Number(body.sessionId);
  if (!Number.isInteger(sessionId) || sessionId < 1 || sessionId > 0xFFFFFFFF) {
    throw new Error("invalid session ID");
  }
  if (typeof body.room !== "string" || !ROOM_PATTERN.test(body.room)) {
    throw new Error("room must use 2-64 letters, numbers, underscores or hyphens");
  }
  if (typeof body.name !== "string" || body.name.trim().length === 0) {
    throw new Error("name is required");
  }
  const transport = body.transport ?? "udp";
  if (transport !== "udp" && transport !== "webrtc") {
    throw new Error("transport must be udp or webrtc");
  }
  return {
    sessionId,
    room: body.room,
    name: body.name.trim().slice(0, 32),
    transport
  };
}

export class SignalingServer extends EventEmitter {
  constructor(config, options = {}) {
    super();
    this.config = config;
    this.issueWebRTCToken = options.issueWebRTCToken;
    this.server = net.createServer((socket) => this.#accept(socket));
    this.clients = new Set();
    this.tokens = new Map();
    this.members = new Map();
    this.started = false;
  }

  async start() {
    if (this.started) return this.server.address();
    this.server.on("error", (error) => this.emit("error", error));
    await new Promise((resolve, reject) => {
      const onError = (error) => reject(error);
      this.server.once("error", onError);
      this.server.listen(this.config.port, this.config.host, () => {
        this.server.off("error", onError);
        resolve();
      });
    });
    this.started = true;
    return this.server.address();
  }

  async stop() {
    for (const client of this.clients) client.socket.destroy();
    this.clients.clear();
    this.tokens.clear();
    this.members.clear();
    if (!this.started) return;
    await new Promise((resolve) => this.server.close(resolve));
    this.started = false;
  }

  authorizeUDPJoin({ body, packet, room, name }) {
    if (typeof body.token !== "string") return false;
    const client = this.tokens.get(body.token);
    if (!client || client.socket.destroyed) return false;
    return (
      client.sessionId === packet.sessionId &&
      client.room === room &&
      client.name === name
    );
  }

  confirmJoined(member) {
    const client = [...this.clients].find(
      (candidate) =>
        candidate.sessionId === member.sessionId &&
        candidate.room === member.room &&
        !candidate.socket.destroyed
    );
    if (!client) return;
    if (client.token) this.tokens.delete(client.token);
    client.token = null;
    client.joined = true;
    this.members.set(member.sessionId, client);
    this.#send(client, {
      action: "joined",
      room: member.room,
      sessionId: member.sessionId
    });
  }

  broadcastSnapshot(room, participants) {
    for (const client of this.members.values()) {
      if (client.room === room && !client.socket.destroyed) {
        this.#send(client, { action: "snapshot", participants });
      }
    }
  }

  #accept(socket) {
    socket.setEncoding("utf8");
    socket.setKeepAlive(true, 5000);
    socket.setNoDelay(true);
    const client = {
      socket,
      buffer: "",
      sessionId: null,
      room: null,
      name: null,
      token: null,
      joined: false,
      transport: null,
      pending: 0,
      queue: Promise.resolve()
    };
    this.clients.add(client);

    socket.on("data", (chunk) => this.#receive(client, chunk));
    socket.on("error", () => this.#remove(client));
    socket.on("close", () => this.#remove(client));
  }

  #receive(client, chunk) {
    client.buffer += chunk;
    let newline;
    while ((newline = client.buffer.indexOf("\n")) >= 0) {
      const line = client.buffer.slice(0, newline);
      client.buffer = client.buffer.slice(newline + 1);
      if (Buffer.byteLength(line, "utf8") > MAX_LINE_BYTES || client.pending >= 64) {
        client.socket.destroy();
        return;
      }
      if (!line.trim()) continue;
      try {
        const body = JSON.parse(line);
        client.pending += 1;
        // Token signing is asynchronous. Preserve TCP message order so one
        // join cannot receive another join's room or leave stale membership.
        client.queue = client.queue.then(() => this.#handle(client, body)).catch((error) => {
          this.#send(client, {
            action: "error",
            message: error instanceof Error ? error.message : "invalid signaling message"
          });
        }).finally(() => { client.pending -= 1; });
      } catch (error) {
        this.#send(client, {
          action: "error",
          message: error instanceof Error ? error.message : "invalid signaling message"
        });
      }
    }
    if (Buffer.byteLength(client.buffer, "utf8") > MAX_LINE_BYTES) {
      client.socket.destroy();
    }
  }

  async #handle(client, body) {
    if (client.socket.destroyed) return;
    if (!body || typeof body !== "object" || Array.isArray(body)) {
      throw new Error("signaling message must be an object");
    }
    if (body.action === "join") {
      const join = normalizeJoin(body);
      if (client.token) this.tokens.delete(client.token);
      if (client.joined && client.sessionId !== join.sessionId) {
        this.emit("leaveSession", client.sessionId);
        this.members.delete(client.sessionId);
      }
      Object.assign(client, join, { joined: false });
      if (join.transport === "webrtc") {
        if (!this.issueWebRTCToken) {
          throw new Error("WebRTC transport is not configured");
        }
        const credentials = await this.issueWebRTCToken(join);
        if (client.socket.destroyed) return;
        client.joined = true;
        this.#send(client, {
          action: "webrtc_connect",
          url: credentials.url,
          token: credentials.token,
          room: client.room
        });
        return;
      }
      client.token = crypto.randomBytes(24).toString("base64url");
      this.tokens.set(client.token, client);
      this.#send(client, {
        action: "udp_bind",
        token: client.token,
        room: client.room
      });
    } else if (body.action === "heartbeat") {
      this.#send(client, { action: "heartbeat_ack" });
    } else if (body.action === "leave") {
      client.socket.end();
    } else {
      throw new Error("unknown signaling action");
    }
  }

  #send(client, body) {
    if (!client.socket.destroyed) {
      client.socket.write(`${JSON.stringify(body)}\n`);
    }
  }

  #remove(client) {
    if (!this.clients.delete(client)) return;
    if (client.token) this.tokens.delete(client.token);
    if (client.joined && this.members.get(client.sessionId) === client) {
      this.members.delete(client.sessionId);
      this.emit("leaveSession", client.sessionId);
    }
  }
}
