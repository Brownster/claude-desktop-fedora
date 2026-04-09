# Release process

## Tag naming convention

```
v<upstream_version>-packaging.<N>
```

Examples:
- `v0.10.14-packaging.1` — first packaging of upstream 0.10.14
- `v0.10.14-packaging.2` — packaging fix, same upstream version
- `v0.10.15-packaging.1` — new upstream version

## Releasing a new upstream version

When the [scheduled check](.github/workflows/scheduled-check.yml) opens an issue saying
a new upstream version is available:

```bash
# 1. Pull latest main
git checkout main && git pull

# 2. Test build locally
./packaging/scripts/build-rpm.sh --version X.Y.Z

# 3. Smoke test
sudo dnf install ./dist/claude-desktop-X.Y.Z-1.x86_64.rpm
./tests/smoke/install-smoke.sh

# 4. If everything works, tag
git tag v X.Y.Z-packaging.1
git push origin vX.Y.Z-packaging.1
```

The `release.yml` workflow fires automatically, builds the RPM in CI, and publishes
the GitHub Release with all artifacts and checksums.

## Releasing a packaging fix (same upstream version)

When you need to fix something in the packaging without a new upstream version:

```bash
# Bump the packaging release number
git tag vX.Y.Z-packaging.2
git push origin vX.Y.Z-packaging.2
```

## Manually triggering a build

For testing without tagging:
1. Go to Actions → Build RPM → Run workflow
2. Optionally specify a version

The artifact will be downloadable from the workflow run but won't create a Release.

## What CI produces per release

| Artifact | Description |
|----------|-------------|
| `claude-desktop-X.Y.Z-N.x86_64.rpm` | Binary RPM |
| `claude-desktop-X.Y.Z-N.src.rpm` | Source RPM (rebuilding possible) |
| `claude-desktop-X.Y.Z-N.x86_64.rpm.sha256` | SHA256 of binary RPM |
| `SHA256SUMS` | All checksums |
| `build-metadata.json` | Upstream version, source URL, hashes, git commit |

## Updating the Fedora version

The CI container is `fedora:42`. To update:
1. Edit the `image:` field in `.github/workflows/build-rpm.yml` and `release.yml`
2. Update the `Fedora version` reference in `generate-release-notes.sh`
3. Test a build
