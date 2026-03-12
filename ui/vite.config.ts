import { defineConfig } from "vite";
import { svelte } from "@sveltejs/vite-plugin-svelte";

export default defineConfig({
  clearScreen: false,
  plugins: [svelte()],
  server: {
    port: 1420,
    strictPort: true
  },
  preview: {
    port: 1420,
    strictPort: true
  }
});
