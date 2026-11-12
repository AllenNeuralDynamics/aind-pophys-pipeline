#!/usr/bin/env bash
# Print info about a pipeline step image.
#
# Usage:
#   image_info.sh <step> <field>
#
#   step:  a key of environment/images.json (CONVERTER, DFF, ...)
#   field: name       -> ghcr.io/allenneuraldynamics/<image_name>
#          dockerfile -> Dockerfile_<x> (relative to environment/)
#          python     -> the step's Python version
#          stage_dir  -> the step's environment/stages/ folder name
#          hash       -> content hash of the files the image is built from
#                        (its Dockerfile, shared build files and stage folder)
#
# The hash is stored as the `org.aind.env-hash` label on each built image and
# is used to decide whether an existing tag is up to date with environment/.
set -euo pipefail

STEP="${1:?step required (a key of environment/images.json)}"
FIELD="${2:?field required (name|dockerfile|python|stage_dir|hash)}"
REPO_ROOT="$(git rev-parse --show-toplevel)"
IMAGES_JSON="$REPO_ROOT/environment/images.json"

if ! jq -e --arg s "$STEP" 'has($s)' "$IMAGES_JSON" >/dev/null; then
  echo "Unknown step: $STEP (valid: $(jq -r 'keys | join("|")' "$IMAGES_JSON"))" >&2
  exit 64
fi

DOCKERFILE=$(jq -r --arg s "$STEP" '.[$s].dockerfile' "$IMAGES_JSON")
STAGE_DIR=$(echo "$STEP" | tr '[:upper:]' '[:lower:]')

case "$FIELD" in
  name)       echo "ghcr.io/allenneuraldynamics/$(jq -r --arg s "$STEP" '.[$s].image_name' "$IMAGES_JSON")";;
  dockerfile) echo "$DOCKERFILE";;
  python)     jq -r --arg s "$STEP" '.[$s].python' "$IMAGES_JSON";;
  stage_dir)  echo "$STAGE_DIR";;
  hash)
    cd "$REPO_ROOT/environment"
    cat "$DOCKERFILE" builder-requirements.txt runtime-check.py conda-overlay-check.py \
      $(find "stages/$STAGE_DIR" -type f | LC_ALL=C sort) | sha256sum | cut -c1-16;;
  *) echo "Unknown field: $FIELD" >&2; exit 64;;
esac
