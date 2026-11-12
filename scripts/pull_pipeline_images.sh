#!/usr/bin/env bash
# Pre-pull the pipeline's step images, so runs do not pull them on first use.
# Optional: without it, Nextflow pulls each image the first time a step runs.
#
# Usage:
#   pull_pipeline_images.sh [--engine ENGINE] [--cache CACHE_DIR] [--steps STEPS] [--save]
#
# Defaults:
#   --engine : apptainer or singularity (auto-detected), or docker
#   --cache  : $NXF_APPTAINER_CACHEDIR or $NXF_SINGULARITY_CACHEDIR (apptainer/singularity only)
#   --steps  : all, or a comma-separated list such as CONVERTER,MOTION_CORRECTION
#   --save   : with docker, also write each image to CACHE_DIR/<name>.tar.zst for transfer to a
#              machine without internet access; restore with
#                for f in CACHE_DIR/*.tar.zst; do zstd -dc "$f" | docker load; done
#
# Images come from pipeline/images.env, with any step overridden in pipeline/images_custom.env.

set -euo pipefail

ENGINE=""
CACHE_DIR="${NXF_APPTAINER_CACHEDIR:-${NXF_SINGULARITY_CACHEDIR:-}}"
STEPS="all"
SAVE=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --engine) ENGINE="$2"; shift 2;;
    --cache) CACHE_DIR="$2"; shift 2;;
    --steps) STEPS="$2"; shift 2;;
    --save) SAVE=true; shift;;
    *) echo "Unknown arg: $1" >&2; exit 64;;
  esac
done

if [[ -z "$ENGINE" ]]; then
  if command -v apptainer >/dev/null 2>&1; then
    ENGINE="apptainer"
  elif command -v singularity >/dev/null 2>&1; then
    ENGINE="singularity"
  elif command -v docker >/dev/null 2>&1; then
    ENGINE="docker"
  else
    echo "ERROR: none of apptainer, singularity or docker found in PATH" >&2
    exit 127
  fi
fi
case "$ENGINE" in
  apptainer|singularity|docker) command -v "$ENGINE" >/dev/null 2>&1 || { echo "ERROR: $ENGINE not found in PATH" >&2; exit 127; };;
  *) echo "ERROR: invalid --engine '$ENGINE' (valid: apptainer, singularity, docker)" >&2; exit 65;;
esac
if [[ "$ENGINE" != "docker" || "$SAVE" == true ]] && [[ -z "$CACHE_DIR" ]]; then
  echo "ERROR: provide --cache or set \$NXF_APPTAINER_CACHEDIR" >&2
  exit 64
fi
if [[ "$SAVE" == true ]] && ! command -v zstd >/dev/null 2>&1; then
  echo "ERROR: zstd not found in PATH (required with --save)" >&2
  exit 127
fi

PIPELINE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../pipeline" && pwd)"
manifests=("$PIPELINE_DIR/images.env")
[[ -f "$PIPELINE_DIR/images_custom.env" ]] && manifests+=("$PIPELINE_DIR/images_custom.env")
# STEP=image lines, later files overriding earlier ones (portable to bash 3).
MANIFEST="$(awk -F= '/^[[:space:]]*#/ || NF < 2 {next} {gsub(/[[:space:]]/, ""); v[$1]=substr($0, index($0, "=") + 1)} END {for (k in v) print k "=" v[k]}' "${manifests[@]}" | sort)"
image_for() { printf '%s\n' "$MANIFEST" | awk -F= -v k="$1" '$1 == k {print substr($0, index($0, "=") + 1)}'; }

if [[ "$STEPS" == "all" ]]; then
  STEPS="$(printf '%s\n' "$MANIFEST" | cut -d= -f1 | paste -sd, -)"
fi
IFS=',' read -r -a SELECTED <<< "$STEPS"

[[ -n "$CACHE_DIR" ]] && mkdir -p "$CACHE_DIR" && export APPTAINER_CACHEDIR="$CACHE_DIR" SINGULARITY_CACHEDIR="$CACHE_DIR"
echo "Engine : $ENGINE"
[[ -n "$CACHE_DIR" ]] && echo "Cache  : $CACHE_DIR"

failed=0
for step in "${SELECTED[@]}"; do
  image="$(image_for "$step")"
  if [[ -z "$image" ]]; then
    echo "ERROR: unknown step '$step' (available: $(printf '%s\n' "$MANIFEST" | cut -d= -f1 | paste -sd, -))" >&2
    exit 65
  fi
  # Nextflow names a cached image after its reference with ':' and '/' replaced by '-'.
  name="${image//:/-}"
  name="${name//\//-}"
  if [[ "$ENGINE" == "docker" ]]; then
    echo "[pull] $step: $image"
    docker pull --platform linux/amd64 "$image" || { failed=$((failed + 1)); continue; }
    if [[ "$SAVE" == true ]]; then
      docker save "$image" | zstd -T0 -3 -q -f -o "$CACHE_DIR/$name.tar.zst"
    fi
  elif [[ -f "$CACHE_DIR/$name.img" ]]; then
    echo "[skip] $step: $CACHE_DIR/$name.img exists"
  else
    echo "[pull] $step: $image to $CACHE_DIR/$name.img"
    "$ENGINE" pull --dir "$CACHE_DIR" "$name.img" "docker://$image" || failed=$((failed + 1))
  fi
done

if [[ "$failed" -gt 0 ]]; then
  echo "ERROR: $failed image(s) failed to pull" >&2
  exit 1
fi
echo "Done."
