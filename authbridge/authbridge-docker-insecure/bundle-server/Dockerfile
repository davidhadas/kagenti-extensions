FROM golang:1.25-alpine AS builder
WORKDIR /app
COPY go.mod ./
COPY main.go ./
COPY internal/ internal/
RUN CGO_ENABLED=0 GOOS=linux go build -ldflags="-s -w" -o /bundle-server .

FROM alpine:3.20
RUN apk add --no-cache ca-certificates
COPY --from=builder --chmod=755 /bundle-server /usr/local/bin/bundle-server
USER 1001
EXPOSE 8090
ENTRYPOINT ["/usr/local/bin/bundle-server"]
