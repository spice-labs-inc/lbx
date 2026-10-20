#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# verify-pi-plugins.sh — runtime integration test: do the Pi upgrade and the
# four plugins actually work inside a built llm-in-a-box image?
#
# WHAT: Builds (or reuses) a llm-in-a-box image for the given RUNTIME_TYPE,
#       starts a throwaway container, and asserts inside the running image:
#         1. pi --version >= 0.74.0 (the @earendil-works rename minimum —
#            magic-context requires it),
#         2. pi list shows all four registered packages (the three ADR-010
#            plugins plus pi-web-access, the 2026-09-03 user-requested one),
#         3. each plugin's extension entry file exists in the pi agent npm
#            tree (module-resolution probe, not source grep), and the aft
#            platform binary is present,
#         4. ~/.config/cortexkit/magic-context.jsonc exists, parses as JSONC,
#            and has historian.pi.model set,
#         5. aft --version executes as the claude user,
#         6. pi --help executes (extension-load sanity) and a headless
#            pi session attempt reports NO extension load errors,
#         7. the claude user owns its own pi settings (root leftovers would
#            break runtime installs),
#         8. the image ships with NO pi credential file (auth is per-user
#            at runtime: /login umans | UMANS_API_KEY — a stale auth.json
#            baked by the build would shadow the user's own login and
#            break provider/model discovery, observed 2026-09-06).
#
# WHY: ADR-010 baked three third-party plugins + the pi package rename into
#      the image; the 2026-09-03 user request added one more
#      (https://pi.dev/packages/pi-web-access). A hostile reviewer (HS-2
#      Step 3) must not trust the Dockerfile text or the build log — this
#      script independently runs the finished image and observes the plugins
#      present and executable, as a real user would (HS-3: "the test
#      passes" is not enough; the artifact must demonstrably work).
#
# USAGE:
#   tests/verify-pi-plugins.sh [RUNTIME_TYPE]     # default: docker
#
# REQUIRES: docker. Builds an image if llm-in-a-box:<RUNTIME_TYPE> does not
# already exist (this can take several minutes on a cold cache). Skips (exit
# 0 with a message) if docker is unusable.
# ---------------------------------------------------------------------------
set -uo pipefail

RUNTIME_TYPE="${1:-docker}"
# Test-only override (mirrors BUILD_VM_MISSING in ./build): point the checks at
# a specific image, e.g. a derived image with an injected leaked credential.
IMAGE="${IMAGE:-llm-in-a-box:${RUNTIME_TYPE}}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${SCRIPT_DIR}/.."
CONTAINER="verify-piplug-$$"

PASS=0
FAIL=0

check() {
    local description="$1"
    local condition="$2"
    if eval "$condition"; then
        echo "[PASS] $description"
        PASS=$((PASS + 1))
    else
        echo "[FAIL] $description"
        FAIL=$((FAIL + 1))
    fi
}

cleanup() {
    docker rm -f "$CONTAINER" >/dev/null 2>&1 || true
}
trap cleanup EXIT

if ! docker info >/dev/null 2>&1; then
    echo "[SKIP] verify-pi-plugins.sh: docker is not usable in this environment"
    exit 0
fi

if ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
    echo "==> Building $IMAGE (image not found locally) ..."
    docker build --build-arg "RUNTIME_TYPE=${RUNTIME_TYPE}" -t "$IMAGE" "$REPO_ROOT" \
        || { echo "[FAIL] image build failed — see the build log above" >&2; exit 1; }
fi

echo "==> Starting throwaway container $CONTAINER ..."
docker run -d --name "$CONTAINER" "$IMAGE" sleep infinity >/dev/null \
    || { echo "[FAIL] container start failed" >&2; exit 1; }

echo "==> Waiting for entrypoint user setup ..."
for _ in $(seq 1 30); do
    docker exec "$CONTAINER" test -f /tmp/.user-ready 2>/dev/null && break
    sleep 1
done

# ── 0. no baked pi credential ships in the image (2026-09-06 incident) ────
# Theory: pi auth is per-user runtime state (PI_SETUP.md documents
# `/login umans` and UMANS_API_KEY). If the image shipped a key-bearing
# auth.json, a stale/expired key would shadow the user's own login and
# break provider/model discovery (observed 2026-09-06: the umans catalog
# could not refresh until the baked key was manually replaced). These
# checks run BEFORE any feature that invokes pi in the container, so they
# observe the image as built: neither the claude profile nor the root
# profile may contain a credential. auth.json may be absent entirely (the
# Dockerfile purge removes it) or present-but-keyless (pi recreates an
# empty stub on first startup); the credential is what must not ship.
# (invariant 12 gate: file-existence checks are permitted here because
# their failure explains why a later auth-behavior test fails — a baked
# credential would be misreported as user configuration.)
check "image ships no key-bearing pi auth.json (claude profile)" \
    "! docker exec '$CONTAINER' bash -c 'grep -Fq \"key\" /home/claude/.pi/agent/auth.json 2>/dev/null'"
check "image ships no key-bearing pi auth.json (root profile)" \
    "! docker exec '$CONTAINER' bash -c 'grep -Fq \"key\" /root/.pi/agent/auth.json 2>/dev/null'"

# ── 1. pi version >= 0.74.0 (ADR-010; pi-install / aft-pi requirement) ──
PI_VER=$(docker exec -u claude "$CONTAINER" pi --version 2>/dev/null || true)
check "pi --version reports at least 0.74.0 (got: ${PI_VER})" \
    "[ -n '$PI_VER' ] && awk -v v='$PI_VER' 'BEGIN{exit !(v+0>=0.74 && v+0>=0)}' "

# ── 2. all registered packages present with pi ──────────────────────────
PI_LIST=$(docker exec -u claude "$CONTAINER" pi list 2>&1 || true)
check "pi list shows pi-provider-umans" \
    "echo '$PI_LIST' | grep >/dev/null 'pi-provider-umans'"
check "pi list shows @cortexkit/aft-pi" \
    "echo '$PI_LIST' | grep >/dev/null '@cortexkit/aft-pi'"
check "pi list shows pi-web-access" \
    "echo '$PI_LIST' | grep >/dev/null 'pi-web-access'"

# ── 3. extension entries + aft binary present in the pi agent npm tree ───
#       (pi install puts npm packages under ~/.pi/agent/npm/node_modules,
#       not the npm global tree — observed in pi 0.84).
check "plugin extension entry files exist (pi npm tree probe)" \
    "docker exec -u claude '$CONTAINER' node -e '
        const path = require(\"path\"), fs = require(\"fs\");
        const g = process.env.HOME + \"/.pi/agent/npm/node_modules\";
        for (const p of [\"pi-provider-umans\", \"@cortexkit/aft-pi\", \"pi-web-access\"]) {
            const base = path.join(g, p);
            if (!fs.existsSync(path.join(base, \"package.json\"))) throw new Error(\"missing package: \" + p);
            const pkg = JSON.parse(fs.readFileSync(path.join(base, \"package.json\"), \"utf8\"));
            // pi extensions may declare their entry via `main` (older style)
            // or the pi-specific `pi.extensions` array (pi-web-access uses
            // the latter).
            const entryRel = pkg.main
                || (pkg.pi && pkg.pi.extensions && pkg.pi.extensions[0])
                || "index.js";
            const entry = path.join(base, entryRel);
            if (!fs.existsSync(entry)) throw new Error(\"missing entry \" + entry + \" for \" + p);
            console.log(\"OK \" + p + \" -> \" + entry);
        }
    '"

check "aft linux-x64 platform binary is present" \
    "docker exec -u claude '$CONTAINER' test -x /home/claude/.pi/agent/npm/node_modules/@cortexkit/aft-linux-x64/bin/aft"

# ── 4. magic-context default config parses and has a historian model ──────
check "magic-context.jsonc exists, parses, and sets historian.pi.model" \
    "docker exec -u claude '$CONTAINER' node -e '
        const fs = require(\"fs\");
        const f = process.env.HOME + \"/.config/cortexkit/magic-context.jsonc\";
        const raw = fs.readFileSync(f, \"utf8\");
        const stripped = raw.split(\"\\n\").filter(l => !l.trim().startsWith(\"//\")).join(\"\\n\");
        const cfg = JSON.parse(stripped);
        if (!cfg.historian || !cfg.historian.pi || typeof cfg.historian.pi.model !== \"string\") {
            throw new Error(\"historian.pi.model missing\");
        }
        console.log(\"OK historian.pi.model = \" + cfg.historian.pi.model);
    '"

# ── 5. aft binary executes as the claude user ─────────────────────────────
check "aft --version runs as the claude user" \
    "docker exec -u claude '$CONTAINER' aft --version >/dev/null 2>&1"

# ── 6. pi extension-load sanity: --help works; a headless session attempt
#       (auth failure expected — no key) must report NO extension load
#       errors. The headless check is gated on a live container AND
#       non-empty output so a dead container can never pass it vacuously.
check "pi --help executes" \
    "docker exec -u claude '$CONTAINER' pi --help >/dev/null 2>&1"

docker exec -u claude "$CONTAINER" bash -c 'timeout 60 pi -p "ping" --provider anthropic 2>&1 || true' \
    > /tmp/pi-headless.out 2>&1
check "headless pi run reports no extension load errors" \
    "docker inspect '$CONTAINER' >/dev/null 2>&1 \
        && [ -s /tmp/pi-headless.out ] \
        && ! grep -qiE 'failed to load extension|error loading extension|failed to load package|extension.*error' /tmp/pi-headless.out"

# ── 6b. pi startup without /login must not conjure a credential ──────────
# Theory: the headless pi run above started pi with NO key configured in
# this container. If a key-bearing auth.json exists now, either the image
# baked one in or runtime/build wiring auto-populated it — both break the
# documented per-user login flow (PI_SETUP.md: /login umans | UMANS_API_KEY)
# and both reproduce the 2026-09-06 incident (stale baked key shadowing the
# user's own login). pi may create a keyless stub ("{}") on first startup;
# the credential is what must not appear without an explicit login.
check "pi startup without /login creates no key-bearing auth.json" \
    "! docker exec '$CONTAINER' bash -c 'grep -Fq \"key\" /home/claude/.pi/agent/auth.json 2>/dev/null'"

# ── 7. claude user owns its pi settings (root leftovers would break the
#       user's runtime `pi install`/`pi update`) ───────────────────────────
check "claude owns ~/.pi/agent/settings.json" \
    "[ \"\$(docker exec '$CONTAINER' stat -c '%U' /home/claude/.pi/agent/settings.json 2>/dev/null)\" = 'claude' ]"
check "claude owns the magic-context config" \
    "[ \"\$(docker exec '$CONTAINER' stat -c '%U' /home/claude/.config/cortexkit/magic-context.jsonc 2>/dev/null)\" = 'claude' ]"

echo ""
echo "verify-pi-plugins.sh: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]
