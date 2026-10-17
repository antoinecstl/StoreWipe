#!/usr/bin/env bash
# Exécute les tests du paquet PhotoSwipeKit sous Linux, dans Docker.
# Usage : Tools/test-linux.sh [arguments supplémentaires pour `swift test`]
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
IMAGE="${PHOTOSWIPE_TEST_IMAGE:-photoswipe-swift:6.2}"

if ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
    docker build --network host -t "$IMAGE" "$ROOT/Tools/docker"
fi

docker run --rm \
    -v "$ROOT/Packages/PhotoSwipeKit:/pkg" \
    -v photoswipe-build:/pkg/.build \
    -w /pkg \
    "$IMAGE" \
    swift test "$@"
