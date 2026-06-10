import react from "@vitejs/plugin-react";
import { defineConfig } from "vite";

// In production the app is served from miniapp.ai-assistant.gg with the
// control-plane API reverse-proxied under /api (see deploy/nginx vhost).
// In dev, proxy /api to a locally running cp-api (PORT defaults to 8080).
export default defineConfig({
  plugins: [react()],
  server: {
    port: 5173,
    proxy: {
      "/api": {
        target: process.env.MINIAPP_DEV_API ?? "http://127.0.0.1:8080",
        changeOrigin: true,
        ws: true, // /api/live (LiveActivity WebSocket)
        rewrite: (p) => p.replace(/^\/api/, ""),
      },
    },
  },
  build: {
    outDir: "dist",
    sourcemap: true,
  },
});
