#!/usr/bin/env bash
# Rust add-ons: the eight cargo binaries the image has always carried.
#
# None of these are needed day to day, and they are the most expensive thing in
# the whole build — compiled from source, roughly nine to ten minutes on eight
# cores. They are therefore a separate, opt-in step:
#
#   lbx-setup rust-extras      (a slim box: only if you want them)
#   ./build docker             (the full image: runs every step, as before)
#
# `rust-extras` alone is enough: when the base toolchain is missing this step
# runs 20-rust.sh first, so there is no "run step X first" to remember.
#
# One tool per `cargo install`: measured, a single batched invocation with all
# eight is SLOWER (the union of their dependency requirements pulls in several
# versions of the same crates and builds them all), and per-tool installs also
# mean a re-run retries only what is missing.
set -euo pipefail
# shellcheck source=/dev/null
. "${LBX_PROVISION_LIB:-/opt/llm-in-a-box/provision-lib.sh}"

CARGO_BIN="$CARGO_HOME_DIR/bin"
# The crate name is not always the binary name: cargo-edit installs cargo-add,
# cargo-rm, cargo-set-version and cargo-upgrade. The probe is what proves the
# tool is usable, and what makes a re-run skip the install.
TOOLS=(wasm-pack cargo-watch cargo-edit cargo-expand cargo-audit cargo-outdated cargo-deny sccache)
probe_of() {
    case "$1" in
        cargo-edit) echo cargo-add ;;
        *) echo "$1" ;;
    esac
}

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ ! -x "$CARGO_BIN/rustc" ]; then
    log "the Rust toolchain is missing; running 20-rust.sh first"
    bash "$HERE/20-rust.sh"
fi
if [ ! -x "$CARGO_BIN/rustc" ]; then
    echo "ERROR: the Rust toolchain is still missing after 20-rust.sh." >&2
    exit 1
fi

for tool in "${TOOLS[@]}"; do
    probe="$(probe_of "$tool")"
    if [ -x "$CARGO_BIN/$probe" ]; then
        log "$tool already present"
        continue
    fi
    log "cargo install $tool (compiled from source)"
    as_box cargo install "$tool"
    if [ ! -x "$CARGO_BIN/$probe" ]; then
        echo "ERROR: $tool did not install ($probe is missing)." >&2
        exit 1
    fi
done

link_cargo_bins
record rust-extras
log "rust add-ons ready"
