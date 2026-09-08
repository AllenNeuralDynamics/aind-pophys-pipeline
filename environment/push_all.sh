#!/usr/bin/env bash
# Publishing must use the same validated build inputs and a unique candidate tag.
set -euo pipefail
echo 'Use build_all.sh "<STAGES>" --tag candidate-<unique-label> --publish, or the manual Images workflow.' >&2
echo 'Publication is refused unless the target GHCR package is pre-created as private.' >&2
exit 1
