import crypto from "node:crypto";
import dgram from "node:dgram";
import net from "node:net";
import { buildControlPacket } from "../src/protocol.js";

const host = process.argv[2] || "127.0.0.1";
const port = Number.parseInt(process.argv[3] || "9000", 10);
if (!Number.isInteger(port) || port < 1 || port > 65535) {
  console.error("Usage: npm run check -- <host> <port>");
  process.exit(2);
}

const sessionId = crypto.randomInt(1, 0xFFFFFFFF);
const tcp = net.createConnection({ host, port });
const udp = dgram.createSocket("udp4");
let buffer = "";
let completed = false;

const timeout = setTimeout(() => {
  finish(new Error(`Meeting handshake timed out at ${host}:${port}`));
}, 3000);

function finish(error) {
  if (completed) return;
  completed = true;
  clearTimeout(timeout);
  if (error) {
    console.error(error.message);
    process.exitCode = 1;
  } else {
    console.log(
      `Meeting server reachable at ${host}:${port}; TCP join and UDP bind passed`
    );
  }
  tcp.destroy();
  udp.close();
}

tcp.setEncoding("utf8");
tcp.on("connect", () => {
  tcp.write(`${JSON.stringify({
    action: "join",
    room: "probe",
    name: "connectivity-check",
    sessionId
  })}\n`);
});
tcp.on("error", finish);
tcp.on("data", (chunk) => {
  buffer += chunk;
  let newline;
  while ((newline = buffer.indexOf("\n")) >= 0) {
    const body = JSON.parse(buffer.slice(0, newline));
    buffer = buffer.slice(newline + 1);
    if (body.action === "udp_bind") {
      udp.send(
        buildControlPacket(sessionId, 1, {
          action: "join",
          room: "probe",
          name: "connectivity-check",
          token: body.token
        }),
        port,
        host
      );
    } else if (body.action === "joined") {
      tcp.write(`${JSON.stringify({ action: "leave" })}\n`);
      finish();
    } else if (body.action === "error") {
      finish(new Error(body.message || "server rejected handshake"));
    }
  }
});

