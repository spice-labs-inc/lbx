# Releasing: LLM reference

Human version: [../releasing.md](../releasing.md).

## Facts

- A release is a GitHub release of the launcher binary, made by
  `.github/workflows/release.yml` on a pushed tag `v*`. No image is
  published anywhere; every host builds the box images with `./build`.
- Tag format: `^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$`, C
  locale. The workflow refuses any other `v*` tag before it builds. First
  release v0.1.0. Pre-1.0: breaking = minor bump.
- Build: `rustup target add x86_64-unknown-linux-musl`; `cargo build
  --release --locked --target x86_64-unknown-linux-musl`.
- Artifacts attached to the release: `lbx-x86_64-unknown-linux-musl` (the
  binary) and `lbx-x86_64-unknown-linux-musl.sha256` (`sha256sum` output,
  checked with `sha256sum -c`).
- Release creation: `softprops/action-gh-release@v2` with
  `fail_on_unmatched_files: true`, `body_path` = the notes block, `name` =
  `tag_name` = the tag.
- Workflow permissions: `contents: write`. Runner: `ubuntu-24.04`.
- Re-running the job for the same tag updates the release in place.

## Release notes block (stable format)

```
<!-- llm-in-a-box release: begin -->
- Tag: <tag>
- Commit: <40 hex>
- Binary: lbx-x86_64-unknown-linux-musl (sha256 in lbx-x86_64-unknown-linux-musl.sha256)
<!-- llm-in-a-box release: end -->
```

Parser regexes for consumers, between the fence lines: tag
`^- Tag: (v[0-9]+\.[0-9]+\.[0-9]+)$`, commit `^- Commit: ([0-9a-f]{40})$`,
binary `^- Binary: (\S+) \(sha256 in (\S+)\)$`. Exactly one block per
release body. The body stays editable after publishing: consumers must
also check the downloaded binary against the `.sha256` file and the tag
against the commit they expect.

## Base image

`docker/relay/Dockerfile`: `FROM python:<version>-alpine3.24@sha256:…`,
pinned by version and digest. `.github/dependabot.yml`: docker ecosystem,
`/docker/relay`, weekly, 7-day cooldown, version and digest updates of
the tag (suffix `-alpine3.24` kept); also github-actions and cargo
ecosystems, weekly.
