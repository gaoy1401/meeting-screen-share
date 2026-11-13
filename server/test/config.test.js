import assert from "node:assert/strict";
import test from "node:test";
import { loadConfig } from "../src/config.js";

const credentials = {
  MEETING_LIVEKIT_API_KEY: "test-key",
  MEETING_LIVEKIT_API_SECRET: "test-secret-at-least-thirty-two-characters"
};

test("configuration requires explicit credentials and defaults to loopback", () => {
  assert.throws(() => loadConfig({}), /MEETING_LIVEKIT_API_KEY/);
  assert.throws(() => loadConfig({ ...credentials, MEETING_LIVEKIT_API_SECRET: "short" }));
  assert.equal(loadConfig(credentials).host, "127.0.0.1");
});

test("ports reject partial numbers, fractions and out-of-range values", () => {
  for (const value of ["9000bad", "9.5", "0", "65536", "-1", " 9000"]) {
    assert.throws(() => loadConfig({ ...credentials, MEETING_PORT: value }), /MEETING_PORT/);
  }
  assert.equal(loadConfig({ ...credentials, MEETING_PORT: "9001" }).port, 9001);
});

test("LiveKit URLs require WebSocket schemes without embedded credentials", () => {
  for (const url of ["http://example.com", "wss://user:pass@example.com", "invalid"]) {
    assert.throws(() => loadConfig({ ...credentials, MEETING_LIVEKIT_URL: url }));
  }
  assert.equal(loadConfig({ ...credentials, MEETING_LIVEKIT_URL: "wss://example.com" }).livekitUrl,
    "wss://example.com");
});
