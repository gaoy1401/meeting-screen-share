const endpointKey = ({ address, port }) => `${address}:${port}`;

export class RoomRegistry {
  constructor({ maxParticipantsPerRoom, memberTimeoutMs }) {
    this.maxParticipantsPerRoom = maxParticipantsPerRoom;
    this.memberTimeoutMs = memberTimeoutMs;
    this.rooms = new Map();
    this.endpointRooms = new Map();
  }

  join(endpoint, { room, name, sessionId }, now = Date.now()) {
    const key = endpointKey(endpoint);
    this.leave(endpoint);

    let members = this.rooms.get(room);
    if (!members) {
      members = new Map();
      this.rooms.set(room, members);
    }
    if (members.size >= this.maxParticipantsPerRoom) {
      throw new Error("room is full");
    }

    const member = {
      key,
      address: endpoint.address,
      port: endpoint.port,
      room,
      name,
      sessionId,
      lastSeenAt: now
    };
    members.set(key, member);
    this.endpointRooms.set(key, room);
    return member;
  }

  leave(endpoint) {
    const key = endpointKey(endpoint);
    const room = this.endpointRooms.get(key);
    if (!room) return null;

    const members = this.rooms.get(room);
    const member = members?.get(key) ?? null;
    members?.delete(key);
    this.endpointRooms.delete(key);
    if (members?.size === 0) this.rooms.delete(room);
    return member;
  }

  get(endpoint) {
    const key = endpointKey(endpoint);
    const room = this.endpointRooms.get(key);
    return room ? this.rooms.get(room)?.get(key) ?? null : null;
  }

  getBySession(sessionId) {
    for (const members of this.rooms.values()) {
      for (const member of members.values()) {
        if (member.sessionId === sessionId) return member;
      }
    }
    return null;
  }

  touch(endpoint, now = Date.now()) {
    const member = this.get(endpoint);
    if (member) member.lastSeenAt = now;
    return member;
  }

  peersOf(member) {
    const members = this.rooms.get(member.room);
    if (!members) return [];
    return [...members.values()].filter((candidate) => candidate.key !== member.key);
  }

  participants(room) {
    return [...(this.rooms.get(room)?.values() ?? [])].map(({ sessionId, name }) => ({
      sessionId,
      name
    }));
  }

  prune(now = Date.now()) {
    const removed = [];
    for (const members of this.rooms.values()) {
      for (const member of members.values()) {
        if (now - member.lastSeenAt > this.memberTimeoutMs) {
          removed.push(this.leave(member));
        }
      }
    }
    return removed.filter(Boolean);
  }
}

export { endpointKey };
