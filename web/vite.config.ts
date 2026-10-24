import { svelte } from '@sveltejs/vite-plugin-svelte'
import { defineConfig } from 'vite'

export default defineConfig({
  plugins: [svelte()],
  server: {
    // `swift run typegraph-gateway` listens on 8080.
    proxy: { '/api': 'http://localhost:8080' },
  },
})
