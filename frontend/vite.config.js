import { defineConfig } from 'vite'
import react from '@vitejs/plugin-react'

export default defineConfig({
  plugins: [react()],
  base: '/resilient-payment-gateway/',  // Required for GitHub Pages project sites
})
