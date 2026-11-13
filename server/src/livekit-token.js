import { AccessToken } from "livekit-server-sdk";

export function createLiveKitTokenIssuer(config) {
  return async ({ room, name, sessionId }) => {
    const token = new AccessToken(
      config.livekitApiKey,
      config.livekitApiSecret,
      {
        identity: `meeting-${sessionId}`,
        name,
        ttl: config.livekitTokenTtlSeconds
      }
    );
    token.addGrant({
      roomJoin: true,
      room,
      canPublish: true,
      canSubscribe: true,
      canPublishData: false
    });
    return {
      url: config.livekitUrl,
      token: await token.toJwt()
    };
  };
}
