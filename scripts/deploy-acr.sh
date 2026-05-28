#!/bin/bash
# Copyright (c) Microsoft Corporation.
# Licensed under the PostgreSQL License.

# deploy-acr.sh - Deploy pg_durable to Azure Container Registry
#
# Usage: ./scripts/deploy-acr.sh [options]
#
# Options:
#   --rebuild    Force rebuild even if image exists
#   --tag TAG    Tag to use (default: latest)
#
# Environment Variables (can also be set in .env):
#   ACR_REGISTRY  Registry URL (required, for example: myregistry.azurecr.io)
#   ACR_IMAGE     Image name (default: pg_durable)
#
# Prerequisites:
#   - Docker logged into ACR: az acr login --name <registry>
#
# Examples:
#   ./scripts/deploy-acr.sh                    # Push existing image as :latest
#   ./scripts/deploy-acr.sh --rebuild          # Force rebuild, push as :latest
#   ./scripts/deploy-acr.sh --tag v0.1.0       # Push as :v0.1.0
#   ACR_REGISTRY=myregistry.azurecr.io ./scripts/deploy-acr.sh  # Custom registry

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# Load .env if exists
if [ -f "$PROJECT_DIR/.env" ]; then
    source "$PROJECT_DIR/.env"
fi

# Configuration (can be overridden via .env or environment)
ACR_REGISTRY="${ACR_REGISTRY:-}"
ACR_IMAGE="${ACR_IMAGE:-pg_durable}"
LOCAL_IMAGE="pg_durable:latest"

if [ -z "$ACR_REGISTRY" ]; then
    echo "Error: ACR_REGISTRY is required (for example: myregistry.azurecr.io)"
    exit 1
fi

# Defaults
FORCE_REBUILD=false
TAG="latest"

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --rebuild)
            FORCE_REBUILD=true
            shift
            ;;
        --tag)
            TAG="$2"
            shift 2
            ;;
        *)
            echo "Unknown option: $1"
            exit 1
            ;;
    esac
done

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
NC='\033[0m'

ACR_FULL="$ACR_REGISTRY/$ACR_IMAGE:$TAG"

echo "================================================"
echo "pg_durable ACR Deployment"
echo -e "Target: ${CYAN}$ACR_FULL${NC}"
echo "================================================"
echo ""

# Check if local image exists
if [ "$FORCE_REBUILD" = false ] && docker image inspect "$LOCAL_IMAGE" &>/dev/null; then
    echo -e "${GREEN}Using existing image: $LOCAL_IMAGE${NC}"
else
    echo -e "${YELLOW}Building Docker image (linux/amd64)...${NC}"
    docker build --platform linux/amd64 -t "$LOCAL_IMAGE" -f "$PROJECT_DIR/Dockerfile" "$PROJECT_DIR"
fi

# Tag for ACR
echo -e "${YELLOW}Tagging image...${NC}"
docker tag "$LOCAL_IMAGE" "$ACR_FULL"

# Push to ACR
echo -e "${YELLOW}Pushing to ACR...${NC}"
if ! docker push "$ACR_FULL"; then
    echo ""
    echo -e "${RED}Push failed. Make sure you're logged in:${NC}"
    # Extract registry name from URL (e.g., myregistry.azurecr.io -> myregistry)
    REGISTRY_NAME="${ACR_REGISTRY%%.*}"
    echo "  az acr login --name $REGISTRY_NAME"
    exit 1
fi

echo ""
echo "================================================"
echo -e "${GREEN}Successfully deployed to:${NC}"
echo -e "  ${CYAN}$ACR_FULL${NC}"
echo "================================================"

