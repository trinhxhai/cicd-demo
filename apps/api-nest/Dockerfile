# Stage 1: Build
FROM node:22-alpine AS builder
WORKDIR /app

COPY package.json package-lock.json nx.json ./
RUN npm ci

COPY tsconfig*.json ./
COPY apps/api-nest apps/api-nest
COPY apps/api-express/package.json apps/api-express/tsconfig*.json apps/api-express/
COPY apps/web/package.json apps/web/tsconfig*.json apps/web/
COPY apps/api-python/project.json apps/api-python/

RUN npx nx sync && npx nx run @org/api-nest:prune

# Stage 2: Run
FROM node:22-alpine AS runner
WORKDIR /app

COPY --from=builder /app/apps/api-nest/dist ./
RUN npm ci --omit=dev --ignore-scripts

RUN addgroup -g 1001 nodejs && adduser -D -u 1001 -G nodejs nodejs
USER nodejs

EXPOSE 3000
CMD ["node", "main.js"]
