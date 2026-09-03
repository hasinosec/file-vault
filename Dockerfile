# Use the same supported Node.js major version as the EC2 server.
FROM node:20-alpine

WORKDIR /app

# Copy dependency files first so Docker can reuse this layer when app code changes.
COPY package.json package-lock.json ./
RUN npm ci --omit=dev

# The web application itself. Runtime settings such as S3_BUCKET are supplied
# by the deployment environment, never baked into this image.
COPY server.js ./

# Run the application as an unprivileged Linux user.
RUN addgroup -S filevault && adduser -S filevault -G filevault && chown -R filevault:filevault /app
USER filevault

EXPOSE 3000
CMD ["node", "server.js"]
