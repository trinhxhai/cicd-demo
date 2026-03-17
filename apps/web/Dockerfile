# Stage 1: Build
FROM node:22-alpine AS builder
WORKDIR /app

COPY package.json package-lock.json nx.json ./
RUN npm ci

COPY tsconfig*.json ./
COPY apps/web apps/web

ENV NEXT_TELEMETRY_DISABLED=1
RUN npx nx sync && npx nx build web --prod

# Stage 2: Run
FROM node:22-alpine AS runner
WORKDIR /app

ENV NODE_ENV=production
ENV NEXT_TELEMETRY_DISABLED=1

COPY --from=builder /app/apps/web/.next/standalone ./
COPY --from=builder /app/apps/web/.next/static ./apps/web/.next/static
COPY --from=builder /app/apps/web/public ./apps/web/public

RUN addgroup -g 1001 nodejs && adduser -D -u 1001 -G nodejs nodejs
USER nodejs

EXPOSE 4000
ENV PORT=4000
CMD ["node", "apps/web/server.js"]
