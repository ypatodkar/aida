FROM node:24-bookworm-slim

WORKDIR /app
COPY package.json package-lock.json ./
RUN npm ci --omit=dev && mkdir -p /app/data && chown node:node /app/data
COPY --chown=node:node src ./src

USER node
ENV NODE_ENV=production HOST=0.0.0.0 PORT=8080 DATA_DIR=/app/data
EXPOSE 8080
CMD ["node", "src/server.js"]
