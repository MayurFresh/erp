# OneMatrix API. Node runs the TypeScript sources directly, so there is no build step.
# Build: docker build -t onematrix-api backend
# Run:   docker run --env-file backend/.env -p 8080:8080 -v onematrix-uploads:/data/uploads onematrix-api
# Migrate first with the same image: docker run --env-file backend/.env onematrix-api node src/db/migrate.ts
FROM node:24-slim

ENV NODE_ENV=production \
    PORT=8080 \
    UPLOAD_DIR=/data/uploads
WORKDIR /app

COPY package.json package-lock.json ./
RUN npm ci --omit=dev && npm cache clean --force

COPY src ./src
RUN mkdir -p /data/uploads && chown node:node /data/uploads
VOLUME /data/uploads

USER node
EXPOSE 8080
HEALTHCHECK --interval=30s --timeout=5s --start-period=10s \
  CMD node -e "fetch('http://127.0.0.1:'+process.env.PORT+'/health').then(r=>process.exit(r.ok?0:1),()=>process.exit(1))"
CMD ["node", "src/server.ts"]
