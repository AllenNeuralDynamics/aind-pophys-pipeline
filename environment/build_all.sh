#!/usr/bin/env bash
# Usage: ./build_all.sh "DFF,OASIS" --tag candidate-<unique-label> [--publish]
# Publishing requires each GHCR package to already exist with private visibility.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
exec python3 candidates.py build "$@"
