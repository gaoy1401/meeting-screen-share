const integer = (value, fallback, { min, max, name }) => {
  if (value === undefined || value === "") return fallback;
  const parsed = /^\d+$/.test(String(value)) ? Number(value) : NaN;
  if (!Number.isInteger(parsed) || parsed < min || parsed > max) {
    throw new Error(`${name} must be an integer between ${min} and ${max}`);
  }
  return parsed;
};

export function loadConfig(env = process.env) {
  const livekitApiKey = env.MEETING_LIVEKIT_API_KEY;
  const livekitApiSecret = env.MEETING_LIVEKIT_API_SECRET;
  if (!livekitApiKey || !livekitApiSecret || livekitApiSecret.length < 32) {
    throw new Error(
      "Set MEETING_LIVEKIT_API_KEY and a MEETING_LIVEKIT_API_SECRET of at least " +
      "32 characters. Run python3 scripts/configure-server.py to generate local configuration."
    );
  }
  const livekitUrl = env.MEETING_LIVEKIT_URL || "ws://127.0.0.1:7880";
  const parsedUrl = new URL(livekitUrl);
  if (!["ws:", "wss:"].includes(parsedUrl.protocol) || parsedUrl.username || parsedUrl.password) {
    throw new Error("MEETING_LIVEKIT_URL must be a ws:// or wss:// URL without credentials");
  }
  return {
    host: env.MEETING_HOST || "127.0.0.1",
    port: integer(env.MEETING_PORT, 9000, {
      min: 1,
      max: 65535,
      name: "MEETING_PORT"
    }),
    maxParticipantsPerRoom: integer(env.MEETING_MAX_PARTICIPANTS, 8, {
      min: 2,
      max: 100,
      name: "MEETING_MAX_PARTICIPANTS"
    }),
    memberTimeoutMs: integer(env.MEETING_MEMBER_TIMEOUT_MS, 15_000, {
      min: 5_000,
      max: 300_000,
      name: "MEETING_MEMBER_TIMEOUT_MS"
    }),
    bytesPerSecond: integer(env.MEETING_BYTES_PER_SECOND, 6_000_000, {
      min: 64_000,
      max: 20_000_000,
      name: "MEETING_BYTES_PER_SECOND"
    }),
    burstBytes: integer(env.MEETING_BURST_BYTES, 12_000_000, {
      min: 64_000,
      max: 40_000_000,
      name: "MEETING_BURST_BYTES"
    }),
    livekitUrl,
    livekitApiKey,
    livekitApiSecret,
    livekitTokenTtlSeconds: integer(env.MEETING_LIVEKIT_TOKEN_TTL_SECONDS, 600, {
      min: 60,
      max: 86_400,
      name: "MEETING_LIVEKIT_TOKEN_TTL_SECONDS"
    })
  };
}
