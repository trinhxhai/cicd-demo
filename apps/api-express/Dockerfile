# Stage 1: Build
FROM node:22-alpine AS builder
WORKDIR /app

COPY package.json package-lock.json nx.json ./
RUN npm ci

COPY tsconfig*.json ./
COPY apps/api-express apps/api-express

RUN npx nx sync && npx nx run @org/api-express:prune

# Stage 2: Run
FROM node:22-alpine AS runner
WORKDIR /app

COPY --from=builder /app/apps/api-express/dist ./
RUN npm ci --omit=dev --ignore-scripts

RUN addgroup -g 1001 nodejs && adduser -D -u 1001 -G nodejs nodejs
USER nodejs

EXPOSE 3001
CMD ["node", "main.js"]
