import { defineConfig } from 'vite'
import vue from '@vitejs/plugin-vue'

export default defineConfig({
  plugins: [vue()],
  server: {
    // 本地开发:前端发往 /api 的请求,转发到后端 :8000
    proxy: {
      '/api': 'http://localhost:8000',
    },
  },
})
