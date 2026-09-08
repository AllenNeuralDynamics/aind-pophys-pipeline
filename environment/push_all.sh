#!/usr/bin/env bash
# Push already-built GHCR images from images.tsv.
# Requires: docker login ghcr.io  (a GitHub PAT / Actions token with packages:write).
# Usage: ./push_all.sh [STAGE ...]   (no args = every active row)
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

WANT=("$@")
want() { [ ${#WANT[@]} -eq 0 ] && return 0; for w in "${WANT[@]}"; do [ "$w" = "$1" ] && return 0; done; return 1; }

while IFS=$'\t' read -r stage dockerfile ghcr_repo tag base_public; do
    [[ -z "${stage:-}" || "$stage" == \#* ]] && continue
    want "$stage" || continue
    [ "$base_public" = "yes" ] || continue
    echo "[push] $ghcr_repo:$tag"
    docker push "$ghcr_repo:$tag"
    echo "  -> set ${stage}_IMAGE_OFFCO=$ghcr_repo:$tag in pipeline/capsule_versions.env"
done < images.tsv
