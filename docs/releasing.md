# Releasing

A release of lbx is a GitHub release of the launcher binary. Nothing is
pushed to an image registry: the box images (`llm-in-a-box:docker`,
`:sysbox`, `:vm`) and the relay image are several gigabytes of developer
tooling that every host builds locally with `./build`, and no consumer pulls
them.

## What a release contains

| Artifact | Where |
|---|---|
| `lbx-x86_64-unknown-linux-musl` | attached to the GitHub release: the launcher, built with `cargo build --release --locked --target x86_64-unknown-linux-musl` (a static binary with no runtime dependencies) |
| `lbx-x86_64-unknown-linux-musl.sha256` | attached to the release: `sha256sum` output for the binary |
| the release body | the notes block below, with the tag, the commit and the binary name |
| the tagged source | `build`, the Dockerfile, `entrypoint.sh`, `docker/`, `apparmor/`, `net-policies/`: everything an image build needs |

## Version rules

- A release is a tag `vMAJOR.MINOR.PATCH`: three decimal numbers without
  leading zeros, nothing before or after (no `-rc.1`, no `+build`). The
  workflow refuses any other `v*` tag before it builds anything.
- Before 1.0.0, a breaking change raises the minor number (`v0.1.0` to
  `v0.2.0`), anything else the patch number (`v0.1.0` to `v0.1.1`).
  Breaking means a change to any of: the `lbx` command line, exit codes
  and status file; the run box contract the image must meet
  (`entrypoint.sh`); the policy file format; the deny log format. This is
  a rule for the person choosing the number, not a check.

## How to cut a release

1. Make sure the commit you want is on `main` and its CI run is green.
2. Tag it and push the tag:

   ```
   git tag v0.1.0
   git push origin v0.1.0
   ```

3. Pushing the tag starts `.github/workflows/release.yml`. Watch the
   "Release" workflow run; when it is green, the release exists with both
   files attached.
4. Edit the release on GitHub if you want to add notes above the block:
   what changed for consumers, and anything breaking. Keep the block as it
   is.

## What release.yml does

In order; a failed step stops the job, and nothing after it happens:

1. Checks that the tag is `vMAJOR.MINOR.PATCH`.
2. Installs the stable Rust toolchain and the `x86_64-unknown-linux-musl`
   target.
3. `cargo build --release --locked --target x86_64-unknown-linux-musl`.
4. Copies the binary to `lbx-x86_64-unknown-linux-musl` and writes
   `lbx-x86_64-unknown-linux-musl.sha256` with `sha256sum`.
5. Writes the release body (the block below) and creates the GitHub
   release for the tag with both files attached
   (`softprops/action-gh-release`). The job fails if a file is missing.

### The release notes block

A downstream consumer reads the release from this block, exactly as the
workflow writes it:

```
<!-- llm-in-a-box release: begin -->
- Tag: v0.1.0
- Commit: <the 40-character commit the tag names>
- Binary: lbx-x86_64-unknown-linux-musl (sha256 in lbx-x86_64-unknown-linux-musl.sha256)
<!-- llm-in-a-box release: end -->
```

The notes stay editable after publishing, so a consumer should also check
the binary against the `.sha256` file it downloaded, and the tag against
the commit it expects.

## Verifying a release

```
gh release download v0.1.0 --pattern 'lbx-x86_64-unknown-linux-musl*'
sha256sum -c lbx-x86_64-unknown-linux-musl.sha256
chmod +x lbx-x86_64-unknown-linux-musl
./lbx-x86_64-unknown-linux-musl --help
```

## When something fails

| Symptom | Cause | What to do |
|---|---|---|
| "refusing tag" | the tag is not `vMAJOR.MINOR.PATCH` | delete the tag (`git push --delete origin <tag>`) and push a correct one |
| the build step fails | the crate does not build with `--locked` for the musl target | fix on `main`, then tag a new version; a tag is never moved |
| the release step fails after the build | a GitHub error or a missing permission (`contents: write`) | re-run the job; the release is created or updated in place |

## The relay base image

`docker/relay/Dockerfile` pins its base image by version and digest, so a
rebuild of a release uses the same base. Dependabot
(`.github/dependabot.yml`) checks weekly and opens pull requests for newer
versions and new digests of that tag, each at least 7 days old; it keeps
the `-alpine3.24` suffix, so a move to a newer Alpine release is a manual
change. The relay's refusal rules use the standard library's address
tables, so a base version change deserves a careful review. The pinned
image is exercised by every run of the relay suites in CI.
