import assert from "node:assert/strict";
import test from "node:test";
import { TokenVerifier } from "livekit-server-sdk";
import { createLiveKitTokenIssuer } from "../src/livekit-token.js";

test("LiveKit token issuer creates a room-scoped publish/subscribe grant", async () => {
  const config = {
    livekitUrl: "ws://127.0.0.1:7880",
    livekitApiKey: "test-key",
    livekitApiSecret: "a-test-secret-that-is-at-least-32-bytes-long",
    livekitTokenTtlSeconds: 600
  };
  const issue = createLiveKitTokenIssuer(config);

  const credentials = await issue({
    room: "demo",
    name: "Alice",
    sessionId: 123
  });
  const claims = await new TokenVerifier(
    config.livekitApiKey,
    config.livekitApiSecret
  ).verify(credentials.token);

  assert.equal(credentials.url, config.livekitUrl);
  assert.equal(claims.sub, "meeting-123");
  assert.equal(claims.name, "Alice");
  assert.equal(claims.video.roomJoin, true);
  assert.equal(claims.video.room, "demo");
  assert.equal(claims.video.canPublish, true);
  assert.equal(claims.video.canSubscribe, true);
  assert.equal(claims.video.canPublishData, false);
});
