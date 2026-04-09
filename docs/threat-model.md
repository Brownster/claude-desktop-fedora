# Threat model and trust information

## What you are trusting

Installing this package means trusting several parties and components:

| Component | Who controls it | Trust level |
|-----------|----------------|-------------|
| Claude Desktop application | Anthropic | Upstream vendor — proprietary binary |
| Windows installer source | `claude.ai` (Anthropic CDN) | Official vendor endpoint |
| Linux native bindings | `aaddrick/claude-desktop-debian` | Third-party open-source project |
| Build pipeline scripts | This repo | You can read and verify all code |
| CI validation runner | GitHub Actions | GitHub's infrastructure |

## What we do to establish trust

- **Source URL**: Always downloaded from the official `claude.ai` API endpoint
- **SHA256 recorded**: The upstream installer hash is captured and published in `build-metadata.json` with every release
- **Transparent patching**: All modifications are in `packaging/scripts/patch-linux-runtime.sh` — readable in full
- **CI logs public**: Validation logs are visible in GitHub Actions for push and pull request checks
- **SRPM included**: Source RPM shipped alongside binary RPM so anyone can rebuild

## What this package does NOT do

- Does not run as root (the launcher explicitly avoids it)
- Does not install system services or daemons
- Does not modify system files outside of `/opt/claude-desktop/`, `/usr/bin/`, `/usr/share/`
- Does not phone home on behalf of the packaging (the app itself may — see Anthropic's privacy policy)

## Risks you should know about

### Proprietary binary

The core application is proprietary software from Anthropic. You cannot audit the full
application behaviour. This is the same as using the official Windows or macOS client.

### Unofficial packaging

This is not an official Anthropic Linux release. Anthropic does not test, sign, or
endorse these packages. If Anthropic ships an official Fedora package, prefer that.

### Upstream layout changes

The build pipeline may break silently in edge cases if Anthropic changes the installer
format. The smoke tests and CI pipeline are designed to catch this early.

### Native module provenance

The Linux native bindings come from a third-party open-source project
(`aaddrick/claude-desktop-debian`). This module replaces a Windows-only binary.
You should verify the provenance of that module is acceptable to you.

## Verification steps for paranoid users

```bash
# 1. Check the upstream installer hash matches the EXE you built from
# Compute: sha256sum Claude-*.exe
# Compare against build-metadata.json in the release

# 2. Verify the RPM checksum
sha256sum -c claude-desktop-*.rpm.sha256

# 3. Inspect what's installed
rpm -qlp claude-desktop-*.rpm       # file list
rpm -qip claude-desktop-*.rpm       # package metadata
rpm --scripts -qp claude-desktop-*.rpm  # pre/post scripts

# 4. Check the launcher script
cat /usr/bin/claude-desktop         # readable shell script, no obfuscation
```

## Reporting security issues

Open a GitHub issue tagged `security`. For issues with the upstream Claude application
itself, contact Anthropic directly.
