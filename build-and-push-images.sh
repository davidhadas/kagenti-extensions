#!/bin/bash
set -a
source .env

# Build and push kagenti-extensions images to GitHub Container Registry
# Usage: ./build-and-push-images.sh [--push]

REGISTRY="ghcr.io/davidhadas/kagenti-extensions"
VERSION="${VERSION:-latest}"
PUSH=false

echo $GITHUB_TOKEN | docker login ghcr.io -u davidhadas --password-stdin

# Parse arguments
if [[ "$1" == "--push" ]]; then
    PUSH=true
fi

echo "=========================================="
echo "Building kagenti-extensions images"
echo "Registry: $REGISTRY"
echo "Version: $VERSION"
echo "Push: $PUSH"
echo "=========================================="

# Function to build and optionally push an image
build_and_push() {
    local name=$1
    local dockerfile=$2
    local context=$3
    local full_name="${REGISTRY}/${name}:${VERSION}"
    
    echo ""
    echo "Building ${name}..."
    docker build -f "${dockerfile}" -t "${full_name}" "${context}"
    

    if [ "$PUSH" = true ]; then
        echo "Pushing ${full_name}..."
        docker push "${full_name}"
    fi
}

# 1. AuthBridge unified image (Envoy + authbridge binary)
# Main production image with Envoy proxy
build_and_push "authbridge" \
    "AuthBridge/cmd/authbridge/Dockerfile" \
    "AuthBridge"

# 2. AuthBridge light image (authbridge binary only, no Envoy)
# For waypoint and proxy-sidecar modes
build_and_push "authbridge-light" \
    "AuthBridge/cmd/authbridge/Dockerfile.light" \
    "AuthBridge"

# 3. Client Registration image
# Python-based client registration for Keycloak
build_and_push "client-registration" \
    "AuthBridge/client-registration/Dockerfile" \
    "AuthBridge/client-registration"

# 4. SPIFFE Helper image
# Custom build of spiffe-helper
build_and_push "spiffe-helper" \
    "AuthBridge/spiffe-helper/Dockerfile" \
    "AuthBridge/spiffe-helper"

# 5. Proxy Init image
# iptables initialization container
build_and_push "proxy-init" \
    "AuthBridge/authproxy/Dockerfile.init" \
    "AuthBridge/authproxy"

echo ""
echo "=========================================="
echo "Build complete!"
echo "=========================================="
echo ""
echo "Images built:"
echo "  - ${REGISTRY}/authbridge:${VERSION}"
echo "  - ${REGISTRY}/authbridge-light:${VERSION}"
echo "  - ${REGISTRY}/client-registration:${VERSION}"
echo "  - ${REGISTRY}/spiffe-helper:${VERSION}"
echo "  - ${REGISTRY}/proxy-init:${VERSION}"
echo ""

if [ "$PUSH" = false ]; then
    echo "To push images to registry, run:"
    echo "  ./build-and-push-images.sh --push"
    echo ""
    echo "Or set VERSION and push:"
    echo "  VERSION=v1.0.0 ./build-and-push-images.sh --push"
fi

# Made with Bob
