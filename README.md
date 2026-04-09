# claude-desktop-fedora

Unofficial Fedora RPM package for [Claude Desktop](https://claude.ai/download) by Anthropic.

> **Not affiliated with or supported by Anthropic.**
> See [docs/threat-model.md](docs/threat-model.md) for trust and security information.

## What this is

A reproducible build pipeline that:
1. Downloads the official Windows Claude Desktop installer from Anthropic's servers
2. Extracts the cross-platform Electron app
3. Replaces Windows-only native components with Linux-compatible equivalents
4. Packages the result as an RPM for Fedora / RHEL / compatible systems

## What this is not

- An official Anthropic Linux release
- A port or rewrite — the application code is unchanged
- Endorsed by or affiliated with Anthropic in any way

## Install

### From releases (recommended)

```bash
# Download the latest RPM from Releases
# Verify the checksum first:
sha256sum -c claude-desktop-*.rpm.sha256

# Install
sudo dnf install ./claude-desktop-*.rpm
```

### From DNF repo (if configured)

```bash
# Add the repo (one time)
sudo dnf config-manager --add-repo https://REPO_URL/claude-desktop-fedora.repo

# Install
sudo dnf install claude-desktop
```

### Build from source

```bash
# Install build prerequisites
sudo dnf install -y \
  git curl jq unzip \
  p7zip p7zip-plugins \
  rpm-build rpmdevtools \
  desktop-file-utils \
  file tar xz \
  nodejs npm \
  python3 \
  bubblewrap

# Clone and build
git clone https://github.com/Brownster/claude-desktop-fedora
cd claude-desktop-fedora
./packaging/scripts/build-rpm.sh

# Install
sudo dnf install ./dist/claude-desktop-*.rpm
```

## Usage

```bash
# Launch
claude-desktop

# Launch with GPU disabled (troubleshooting)
CLAUDE_DISABLE_GPU=1 claude-desktop

# MCP config
~/.config/Claude/claude_desktop_config.json
```

## How to verify artifacts

Every release publishes:

| File | Purpose |
|------|---------|
| `claude-desktop-X.Y.Z-N.x86_64.rpm` | The RPM package |
| `claude-desktop-X.Y.Z-N.x86_64.rpm.sha256` | SHA256 of the RPM |
| `SHA256SUMS` | All artifact checksums |
| `build-metadata.json` | Upstream version, source URL, SHA256 of upstream EXE, git commit |

```bash
# Verify RPM integrity
sha256sum -c claude-desktop-*.rpm.sha256
```

The upstream Windows installer SHA256 is recorded in `build-metadata.json` so you can
independently verify that the packaged app matches what Anthropic distributed.

## Supported platforms

| Platform | Status |
|----------|--------|
| Fedora 40+ x86_64 | Primary target |
| RHEL 9 / AlmaLinux 9 | Should work (untested) |
| ARM64 | Not supported |

## Updating

When a new upstream Claude version is available:

1. The [scheduled check](.github/workflows/scheduled-check.yml) opens a GitHub issue automatically
2. Tag a new release: `git tag v0.10.14-packaging.1 && git push --tags`
3. CI builds and publishes the RPM automatically

## Troubleshooting

See [docs/troubleshooting.md](docs/troubleshooting.md).

**Quick checks:**
```bash
# Run from terminal to see errors
claude-desktop

# Check journal
journalctl --user -xe | grep claude

# Wayland issues — force X11
OZONE_PLATFORM=x11 claude-desktop
```

## Architecture

See [docs/architecture.md](docs/architecture.md) for how the build pipeline works.

## Acknowledgements

Build approach based on [aaddrick/claude-desktop-debian](https://github.com/aaddrick/claude-desktop-debian).

## License

The build scripts and spec files in this repository are MIT licensed.
Claude Desktop itself is proprietary software by Anthropic.
