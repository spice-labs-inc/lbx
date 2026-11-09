#!/usr/bin/env bash
# Base Rust toolchain: rustup, the stable toolchain, the wasm target and the
# three components the agents and editors expect (rustfmt, clippy,
# rust-analyzer). This is the part a Rust box needs day to day; the cargo
# add-ons are a separate, optional step (25-rust-extras.sh).
#
# Unpinned on purpose: `rustup update` inside a box is the upgrade path, and a
# rebuild picks up the current stable.
set -euo pipefail
# shellcheck source=/dev/null
. "${LBX_PROVISION_LIB:-/opt/llm-in-a-box/provision-lib.sh}"

if [ ! -x "$CARGO_HOME_DIR/bin/rustc" ]; then
    log "installing rustup + stable toolchain"
    as_box bash -c 'curl --proto "=https" --tlsv1.2 -sSf https://sh.rustup.rs \
        | sh -s -- -y --default-toolchain stable --no-modify-path'
    as_box rustup target add wasm32-unknown-unknown
    as_box rustup component add rustfmt clippy rust-analyzer
    as_box rustup component remove rust-docs || true
else
    log "rust toolchain already present"
fi

# Downloads, the crate registry and the git checkouts are build residue, not
# content: drop them so the image does not carry a second copy of every source.
rm -rf "$RUSTUP_HOME_DIR/downloads" "$RUSTUP_HOME_DIR/tmp" \
    "$CARGO_HOME_DIR/registry" "$CARGO_HOME_DIR/git"

link_cargo_bins
record rust
log "rust toolchain ready"
