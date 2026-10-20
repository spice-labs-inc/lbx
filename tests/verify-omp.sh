#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# verify-omp.sh — runtime integration test: does `omp` actually run inside
# a built llm-in-a-box image?
#
# WHAT: Builds (or reuses) a llm-in-a-box image for the given RUNTIME_TYPE,
#       starts a throwaway container, and runs `omp --version` inside it as
#       the container's default user.
#
# WHY: The bug this remediates was "OMP doesn't work — Bun isn't installed
#      in the container." A Dockerfile RUN-time smoke test (see
#      tests/test_dockerfile.sh) catches this at build time, but a
#      hostile-reviewer check (HS-2 Step 3) should not just trust the build
#      log — it should independently run the finished image and observe
#      `omp` actually execute, as a real user would.
#
# USAGE:
#   tests/verify-omp.sh [RUNTIME_TYPE]     # default: sysbox
#
# REQUIRES: docker. Builds an image if llm-in-a-box:<RUNTIME_TYPE> does not
# already exist (this can take several minutes on a cold cache).
# ---------------------------------------------------------------------------
set -euo pipefail

RUNTIME_TYPE="${1:-sysbox}"
IMAGE="llm-in-a-box:${RUNTIME_TYPE}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${SCRIPT_DIR}/.."
CONTAINER="verify-omp-$$"

cleanup() {
    docker rm -f "$CONTAINER" >/dev/null 2>&1 || true
}
trap cleanup EXIT

if ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
    echo "==> Building $IMAGE (image not found locally) ..."
    docker build --build-arg "RUNTIME_TYPE=${RUNTIME_TYPE}" -t "$IMAGE" "$REPO_ROOT"
fi

echo "==> Starting throwaway container $CONTAINER ..."
docker run -d --name "$CONTAINER" "$IMAGE" sleep infinity >/dev/null

echo "==> Waiting for entrypoint user setup ..."
for _ in $(seq 1 30); do
    docker exec "$CONTAINER" test -f /tmp/.user-ready 2>/dev/null && break
    sleep 1
done

echo "==> Running: bun --version"
docker exec -u claude "$CONTAINER" bun --version

echo "==> Running: omp --version"
docker exec -u claude "$CONTAINER" omp --version

echo ""
echo "[PASS] verify-omp.sh: omp runs successfully inside $IMAGE"
