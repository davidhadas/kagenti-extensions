# AuthBridge unified binary — single binary, three modes.
# Build context: ./authbridge (needs access to both authlib/ and cmd/authbridge/)

FROM golang:1.24-alpine AS builder

RUN apk add --no-cache git

WORKDIR /app

# Copy go.work and both modules
COPY go.work .
COPY authlib/ authlib/
COPY cmd/authbridge/ cmd/authbridge/

# Build
RUN cd cmd/authbridge && CGO_ENABLED=0 GOOS=linux go build -o /authbridge .

# Runtime
FROM gcr.io/distroless/static-debian12

COPY --from=builder /authbridge /authbridge

USER 65534

ENTRYPOINT ["/authbridge"]
