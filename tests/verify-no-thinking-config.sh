#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# verify-no-thinking-config.sh — runtime integration test: the built image
# contains NONE of the removed "thinking mode" provider config files, and
# the agents still run without them.
#
# WHAT: Builds (or reuses) a llm-in-a-box image for the given RUNTIME_TYPE,
#       starts a throwaway container, and asserts inside the running image:
#         - ~/.config/opencode/opencode.json does NOT exist
#         - ~/.omp/agent/models.yml and ~/.omp/agent/config.yml do NOT exist
#         - opencode --version runs (OpenCode works with zero pre-config)
#         - omp --version runs (OMP works with zero pre-config)
#
# WHY: The thinking-mode provider configs (opencode-config.json,
#      omp-models.yml, omp-config.yml) were removed on 2026-09-01 (ADR-009)
#      because they were unnecessary — providers/agents now surface
#      thinking/reasoning natively. This test proves the REMOVAL on the
#      built artifact (behavioral, no source grep — invariant 12/HS-3):
#      a hostile reviewer should not have to trust that the Dockerfile
#      COPY steps were deleted; the shipped image must be observed to not
#      contain the files, and the agents must still execute.
#
# USAGE:
#   tests/verify-no-thinking-config.sh [RUNTIME_TYPE]     # default: docker
#
# REQUIRES: docker. Builds an image if llm-in-a-box:<RUNTIME_TYPE> does not
# already exist (this can take several minutes on a cold cache).
# ---------------------------------------------------------------------------
set -euo pipefail

RUNTIME_TYPE="${1:-docker}"
IMAGE="llm-in-a-box:${RUNTIME_TYPE}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${SCRIPT_DIR}/.."
CONTAINER="verify-nothink-$$"

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

# Requirement (ADR-009): the removed thinking-mode configs must not exist
# anywhere in the image (the three shipped paths are the only ones that
# ever existed; this asserts absence at each).
for f in \
    /home/claude/.config/opencode/opencode.json \
    /home/claude/.omp/agent/models.yml \
    /home/claude/.omp/agent/config.yml; do
    if docker exec -u claude "$CONTAINER" test -e "$f" 2>/dev/null; then
        echo "[FAIL] $f exists — thinking-mode config removal incomplete" >&2
        exit 1
    fi
    echo "[PASS] $f absent"
done

# Requirement: the agents still run with zero pre-config (the configs were
# additive routing only; their removal must not break the agents).
echo "==> Running: opencode --version"
docker exec -u claude "$CONTAINER" opencode --version

echo "==> Running: omp --version"
docker exec -u claude "$CONTAINER" omp --version

echo ""
echo "[PASS] verify-no-thinking-config.sh: no thinking-mode configs present; agents still run in $IMAGE"
