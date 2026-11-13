import assert from "node:assert/strict";
import test from "node:test";
import { RoomRegistry } from "../src/room-registry.js";

const endpoint = (port) => ({ address: "127.0.0.1", port });
const member = (room, sessionId, name = "Test participant") => ({ room, sessionId, name });
const registry = () => new RoomRegistry({ maxParticipantsPerRoom: 2, memberTimeoutMs: 15_000 });

test("a rejected room switch preserves both rooms and the original member", () => {
  const rooms = registry();
  const alice = endpoint(10001);
  const original = rooms.join(alice, member("old-room", 1), 100);
  rooms.join(endpoint(10002), member("full-room", 2), 200);
  rooms.join(endpoint(10003), member("full-room", 3), 300);
  const oldParticipants = rooms.participants("old-room");
  const targetParticipants = rooms.participants("full-room");

  assert.throws(() => rooms.join(alice, member("full-room", 4, "New name"), 999), /room is full/);
  assert.equal(rooms.get(alice), original);
  assert.equal(original.lastSeenAt, 100);
  assert.equal(rooms.getBySession(1), original);
  assert.equal(rooms.getBySession(4), null);
  assert.deepEqual(rooms.participants("old-room"), oldParticipants);
  assert.deepEqual(rooms.participants("full-room"), targetParticipants);
  assert.equal(rooms.endpointRooms.size, 3);
});

test("an existing endpoint can rejoin a full room and refresh its metadata", () => {
  const rooms = registry();
  const alice = endpoint(10001);
  rooms.join(alice, member("same-room", 1), 100);
  rooms.join(endpoint(10002), member("same-room", 2), 100);
  const updated = rooms.join(alice, member("same-room", 3, "Updated name"), 200);
  assert.equal(rooms.get(alice), updated);
  assert.equal(updated.lastSeenAt, 200);
  assert.equal(updated.name, "Updated name");
  assert.equal(rooms.getBySession(1), null);
  assert.equal(rooms.participants("same-room").length, 2);
  assert.equal(rooms.endpointRooms.size, 2);
});

test("a successful switch removes an empty old room", () => {
  const rooms = registry();
  const alice = endpoint(10001);
  rooms.join(alice, member("old-room", 1), 100);
  const moved = rooms.join(alice, member("new-room", 1), 200);
  assert.equal(rooms.rooms.has("old-room"), false);
  assert.equal(rooms.get(alice), moved);
  assert.equal(rooms.endpointRooms.get(moved.key), "new-room");
  assert.deepEqual(rooms.participants("new-room"), [{ sessionId: 1, name: "Test participant" }]);
});

test("a sole participant can rejoin without losing the room map", () => {
  const rooms = registry();
  const alice = endpoint(10001);
  rooms.join(alice, member("same-room", 1), 100);
  const updated = rooms.join(alice, member("same-room", 2), 200);
  assert.equal(rooms.get(alice), updated);
  assert.equal(rooms.rooms.size, 1);
  assert.equal(rooms.rooms.get("same-room").get(updated.key), updated);
  assert.deepEqual(rooms.participants("same-room").map((p) => p.sessionId), [2]);
});

test("a successful switch preserves peers in both rooms", () => {
  const rooms = registry();
  const alice = endpoint(10001);
  rooms.join(alice, member("old-room", 1), 100);
  rooms.join(endpoint(10002), member("old-room", 2), 100);
  rooms.join(endpoint(10003), member("new-room", 3), 100);
  const moved = rooms.join(alice, member("new-room", 1), 200);
  assert.deepEqual(rooms.participants("old-room").map((p) => p.sessionId), [2]);
  assert.deepEqual(rooms.participants("new-room").map((p) => p.sessionId), [3, 1]);
  assert.deepEqual(rooms.peersOf(moved).map((p) => p.sessionId), [3]);
});

test("a full room rejects a new endpoint without changing membership", () => {
  const rooms = registry();
  rooms.join(endpoint(10001), member("full-room", 1));
  rooms.join(endpoint(10002), member("full-room", 2));
  const newcomer = endpoint(10003);
  assert.throws(() => rooms.join(newcomer, member("full-room", 3)), /room is full/);
  assert.equal(rooms.get(newcomer), null);
  assert.deepEqual(rooms.participants("full-room").map((p) => p.sessionId), [1, 2]);
  assert.equal(rooms.endpointRooms.size, 2);
});
