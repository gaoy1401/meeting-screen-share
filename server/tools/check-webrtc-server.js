import crypto from "node:crypto";
import net from "node:net";

const host = process.argv[2] || "127.0.0.1";
const controlPort = Number.parseInt(process.argv[3] || "9000", 10);
if (!Number.isInteger(controlPort) || controlPort < 1 || controlPort > 65535) {
  console.error("Usage: node tools/check-webrtc-server.js <host> <control-port>");
  process.exit(2);
}

function connectTCP(targetHost, targetPort, label) {
  return new Promise((resolve, reject) => {
    const socket = net.createConnection({
      host: targetHost,
      port: targetPort
    });
    const timeout = setTimeout(() => {
      socket.destroy();
      reject(new Error(`${label} timed out at ${targetHost}:${targetPort}`));
    }, 3000);
    socket.once("connect", () => {
      clearTimeout(timeout);
      socket.end();
      resolve();
    });
    socket.once("error", (error) => {
      clearTimeout(timeout);
      reject(new Error(`${label} failed: ${error.message}`));
    });
  });
}

function requestWebRTCCredentials() {
  return new Promise((resolve, reject) => {
    const socket = net.createConnection({ host, port: controlPort });
    const sessionId = crypto.randomInt(1, 0xFFFFFFFF);
    let buffer = "";
    let completed = false;
    const timeout = setTimeout(() => {
      finish(new Error(`Control handshake timed out at ${host}:${controlPort}`));
    }, 3000);

    function finish(error, value) {
      if (completed) return;
      completed = true;
      clearTimeout(timeout);
      socket.destroy();
      if (error) reject(error);
      else resolve(value);
    }

    socket.setEncoding("utf8");
    socket.once("connect", () => {
      socket.write(`${JSON.stringify({
        action: "join",
        room: "probe",
        name: "webrtc-connectivity-check",
        sessionId,
        transport: "webrtc"
      })}\n`);
    });
    socket.once("error", (error) => {
      finish(new Error(`Control connection failed: ${error.message}`));
    });
    socket.on("data", (chunk) => {
      buffer += chunk;
      let newline;
      while ((newline = buffer.indexOf("\n")) >= 0) {
        const line = buffer.slice(0, newline);
        buffer = buffer.slice(newline + 1);
        if (!line.trim()) continue;
        let body;
        try {
          body = JSON.parse(line);
        } catch {
          finish(new Error("Control server returned invalid JSON"));
          return;
        }
        if (body.action === "error") {
          finish(new Error(body.message || "Control server rejected the join"));
          return;
        }
        if (body.action === "webrtc_connect") {
          if (
            typeof body.url !== "string" ||
            typeof body.token !== "string" ||
            body.token.split(".").length !== 3
          ) {
            finish(new Error("Control server returned invalid WebRTC credentials"));
            return;
          }
          socket.write(`${JSON.stringify({ action: "leave" })}\n`);
          finish(null, body);
          return;
        }
      }
    });
  });
}

try {
  const credentials = await requestWebRTCCredentials();
  const liveKitUrl = new URL(credentials.url);
  const liveKitPort = Number.parseInt(
    liveKitUrl.port || (liveKitUrl.protocol === "wss:" ? "443" : "80"),
    10
  );
  await connectTCP(liveKitUrl.hostname, liveKitPort, "LiveKit SFU connection");
  console.log(
    `Mac meeting server passed: control ${host}:${controlPort}, ` +
    `LiveKit ${liveKitUrl.host}, room-scoped JWT issued`
  );
} catch (error) {
  console.error(error instanceof Error ? error.message : String(error));
  process.exitCode = 1;
}
