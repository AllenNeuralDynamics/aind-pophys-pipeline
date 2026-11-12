#!/usr/bin/env bash
# Push images built by build_all.sh and print their digests for pipeline/images.env.
set -euo pipefail

ENV_DIR="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")"
IMAGES_JSON="$ENV_DIR/images.json"
ALL_IMAGES=$(jq -r 'keys_unsorted | join(",")' "$IMAGES_JSON")
REGISTRY="${IMAGE_REGISTRY:-ghcr.io/allenneuraldynamics}"

if [[ -z "${1:-}" ]]; then
    echo "Usage: $0 <container_tag> [target] [images]"
    echo ""
    echo "Arguments:"
    echo "  container_tag: Docker container tag (required)"
    echo "  target: Build target 'main' or 'dev' (default: main)"
    echo "  images: Comma-separated list of images to push, or 'all' (default: all; available: $ALL_IMAGES)"
    exit 1
fi

CONTAINER_TAG_ARG="${1}"
TARGET_ARG="${2:-main}"
IMAGES_ARG="${3:-all}"
[[ "$IMAGES_ARG" == "all" ]] && IMAGES_ARG="$ALL_IMAGES"

if [[ "$TARGET_ARG" != "main" && "$TARGET_ARG" != "dev" ]]; then
    echo "Error: TARGET_ARG must be 'main' or 'dev', got '$TARGET_ARG'"
    exit 1
fi

if [[ "$TARGET_ARG" == "dev" ]]; then
    CONTAINER_TAG_ARG="$CONTAINER_TAG_ARG-dev"
fi

IFS=',' read -r -a IMAGES_LIST <<< "$IMAGES_ARG"

echo "Images to push: ${IMAGES_LIST[*]}"
echo "Push target: $TARGET_ARG"

for image in "${IMAGES_LIST[@]}"; do
    if ! jq -e --arg i "$image" 'has($i)' "$IMAGES_JSON" >/dev/null; then
        echo "Error: unknown image '$image' (available: $ALL_IMAGES)"
        exit 1
    fi
    IMAGE_NAME=$(jq -r --arg i "$image" '.[$i].image_name' "$IMAGES_JSON")
    REPO="$REGISTRY/$IMAGE_NAME"
    echo "Pushing $REPO:$CONTAINER_TAG_ARG"
    docker push "$REPO:$CONTAINER_TAG_ARG"
    DIGEST=$(docker buildx imagetools inspect "$REPO:$CONTAINER_TAG_ARG" --format '{{json .Manifest}}' | jq -r .digest)
    echo "$image=$REPO@$DIGEST"
done
