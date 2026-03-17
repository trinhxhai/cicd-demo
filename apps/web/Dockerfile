# Stage 1: Build
FROM node:22-alpine AS builder
WORKDIR /app

COPY package.json package-lock.json nx.json ./
RUN npm ci

COPY tsconfig*.json ./
COPY apps/web apps/web

ENV NEXT_TELEMETRY_DISABLED=1
RUN npx nx build web --prod

# Stage 2: Run
FROM node:22-alpine AS runner
WORKDIR /app

ENV NODE_ENV=production
ENV NEXT_TELEMETRY_DISABLED=1

COPY --from=builder /app/dist/apps/web/.next/standalone ./
COPY --from=builder /app/dist/apps/web/.next/static ./.next/static
COPY --from=builder /app/dist/apps/web/public ./public

EXPOSE 4000
ENV PORT=4000
CMD ["node", "server.js"]
