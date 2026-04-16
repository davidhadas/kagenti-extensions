# AuthBridge unified image — Envoy + authbridge binary in one container.
# Drop-in replacement for envoy-with-processor (Dockerfile.envoy).
#
# Uses UBI9-micro base (~24 MB) instead of UBI9-minimal (~134 MB)
# for a ~42% smaller image while remaining glibc-compatible for Envoy.
#
# Build context: ./authbridge (needs access to both authlib/ and cmd/authbridge/)

# Stage 1: Build authbridge binary
FROM golang:1.24-alpine AS builder

RUN apk add --no-cache git

WORKDIR /app

# Copy both modules with Docker-compatible layout
COPY authlib/ authlib/
COPY cmd/authbridge/ cmd/authbridge/

# The go.mod has: replace authlib => ../../authlib
# In Docker the layout is /app/authlib and /app/cmd/authbridge, so the
# relative path ../../authlib resolves to /app/authlib. Correct.
ENV GOWORK=off
RUN cd cmd/authbridge && CGO_ENABLED=0 GOOS=linux go build -o /authbridge . \
    && chmod 755 /authbridge

# Stage 2: Get Envoy binary
FROM docker.io/envoyproxy/envoy:v1.37.1 AS envoy-source

# Stage 3: Runtime — UBI9-micro (glibc-compatible, ~24 MB)
FROM registry.access.redhat.com/ubi9/ubi-micro:latest

COPY --from=envoy-source --chmod=755 /usr/local/bin/envoy /usr/local/bin/envoy
COPY --from=builder --chmod=755 /authbridge /usr/local/bin/authbridge
COPY --chmod=755 cmd/authbridge/entrypoint.sh /usr/local/bin/entrypoint.sh

# Envoy writes hot-restart lock files and admin socket here
RUN mkdir -p /tmp/envoy && chmod 775 /tmp/envoy

USER 1337

EXPOSE 15123 15124 9901 9090

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
