#!/usr/bin/env bash
# Build off-CO GHCR images from images.tsv. Requires Docker with BuildKit.
# Usage: ./build_all.sh [STAGE ...]   (no args = every active row in images.tsv)
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

WANT=("$@")
want() { [ ${#WANT[@]} -eq 0 ] && return 0; for w in "${WANT[@]}"; do [ "$w" = "$1" ] && return 0; done; return 1; }

built=0
while IFS=$'\t' read -r stage dockerfile ghcr_repo tag base_public; do
    [[ -z "${stage:-}" || "$stage" == \#* ]] && continue
    want "$stage" || continue
    if [ "$base_public" != "yes" ]; then
        echo "[skip] $stage: base_public=$base_public (re-base onto a public image first)" >&2
        continue
    fi
    [ -f "$dockerfile" ] || { echo "[err] $stage: $dockerfile missing" >&2; exit 1; }
    echo "[build] $ghcr_repo:$tag  <-  $dockerfile"
    DOCKER_BUILDKIT=1 docker build --platform linux/amd64 -f "$dockerfile" -t "$ghcr_repo:$tag" .
    built=$((built+1))
done < images.tsv
echo "[done] built $built image(s)."
