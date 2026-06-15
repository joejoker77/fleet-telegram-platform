// M5.4 — GET /live (WebSocket): stream the tenant's own audit events to the
// Mini App in real time. Producer: audit-collector publishes every attributed
// event to Redis pub/sub channel `live:<userId>`; this route subscribes and
// forwards. Best-effort by design — the WORM audit file is the durable record.
//
// Auth: browsers can't set headers on WebSocket upgrades, so the JWT comes as
// ?token=. The JWT is short-lived + Redis-revocable (same verifySession as the
// REST routes), which bounds the exposure of a token in a URL.

import type { FastifyInstance } from "fastify";
import { Redis } from "ioredis";
import type { Redis as RedisClient } from "ioredis";

import { verifySession } from "./auth.js";

export interface LiveDeps {
  redis: RedisClient;
  redisUrl: string;
  jwtSecret: Uint8Array; // same HS256 key bytes verifySession expects
}

export function registerLiveRoutes(app: FastifyInstance, deps: LiveDeps): void {
  app.get("/live", { websocket: true }, async (socket, req) => {
    const token = (req.query as { token?: string }).token ?? "";
    let sub: string;
    try {
      ({ sub } = await verifySession(deps.redis, deps.jwtSecret, token));
    } catch {
      socket.close(4401, Buffer.from("invalid or expired session"));
      return;
    }

    // Pub/sub puts an ioredis connection in subscriber mode, so each ws gets
    // its own dedicated connection (cannot share the command client).
    const subscriber = new Redis(deps.redisUrl, { maxRetriesPerRequest: 1 });
    const channel = `live:${sub}`;

    // Heartbeat: while a tenant is idle no audit frames flow, and Cloudflare
    // (in front of miniapp.ai-assistant.gg) drops a WebSocket after ~100s of
    // silence. The client then auto-reconnects, logging a fresh "live.hello" —
    // visually noisy churn. A periodic ping keeps the connection alive through
    // CF without surfacing in the event feed (control frames aren't onmessage).
    const HEARTBEAT_MS = 30_000;
    const heartbeat = setInterval(() => {
      if (socket.readyState === socket.OPEN) {
        try {
          socket.ping();
        } catch {
          /* socket dying — the close handler will clean up */
        }
      }
    }, HEARTBEAT_MS);

    const cleanup = () => {
      clearInterval(heartbeat);
      subscriber.disconnect();
    };

    subscriber.on("error", () => {
      /* transient redis errors: keep the ws open; messages resume on reconnect */
    });
    subscriber.on("message", (ch, message) => {
      if (ch === channel && socket.readyState === socket.OPEN) socket.send(message);
    });

    try {
      await subscriber.subscribe(channel);
    } catch {
      cleanup();
      socket.close(1011, Buffer.from("subscribe failed"));
      return;
    }

    socket.send(JSON.stringify({ kind: "live.hello", ts: new Date().toISOString() }));
    socket.on("close", cleanup);
    socket.on("error", cleanup);
  });
}
