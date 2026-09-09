#!/usr/bin/env bash
# Usage: ./build_all.sh "DFF,OASIS" --tag candidate-<unique-label> [--publish]
# Existing packages must be Private or Internal; publication verifies visibility.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
exec python3 candidates.py build "$@"
