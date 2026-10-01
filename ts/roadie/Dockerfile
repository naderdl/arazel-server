FROM node:lts-alpine3.24@sha256:ebfe2f90462722a7a4de65e91990e97fe0d401c70e0e762c5b53302f905ec1c1

# knkwebservices/ts6-roadie v0.18.0
ARG ROADIE_REVISION=172d001f01bb90ef7898ac81ab9cce7b0536b9c4
ARG YTDLP_VERSION=2026.08.19
LABEL org.opencontainers.image.source="https://github.com/knkwebservices/ts6-roadie" \
      org.opencontainers.image.revision="172d001f01bb90ef7898ac81ab9cce7b0536b9c4"

RUN apk add --no-cache ca-certificates curl ffmpeg python3 zip unzip

RUN curl -fsSL "https://github.com/yt-dlp/yt-dlp/releases/download/${YTDLP_VERSION}/yt-dlp" -o /usr/local/bin/yt-dlp \
 && echo '1fa6733c37ea6fb51c99ad8fe785e7b7e5f3246c9b980230329d4fb72ed8d4d6  /usr/local/bin/yt-dlp' | sha256sum -c - \
 && chmod 755 /usr/local/bin/yt-dlp

WORKDIR /app
RUN curl -fsSL "https://codeload.github.com/knkwebservices/ts6-roadie/tar.gz/${ROADIE_REVISION}" \
    | tar -xz --strip-components=1 \
 && npm ci --registry=https://package-mirror.liara.ir/repository/npm/ --replace-registry-host=registry.npmjs.org \
 && npm run build

ENV NODE_ENV=production TSBOT_DATA=/data
CMD ["node", "dist/index.js"]
