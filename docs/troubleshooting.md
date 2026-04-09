# Troubleshooting

## App doesn't start

Run from terminal to see error output:
```bash
claude-desktop
```

Check the journal:
```bash
journalctl --user -xe | grep -i claude
```

### "error while loading shared libraries"

A runtime library is missing. Install it:
```bash
ldd /opt/claude-desktop/claude | grep "not found"
sudo dnf install <missing-lib-package>
```

Common culprits and their packages:
| Library | Package |
|---------|---------|
| `libnss3.so` | `nss` |
| `libatk-1.0.so.0` | `atk` |
| `libgbm.so.1` | `mesa-libgbm` |
| `libXScrnSaver.so.1` | `libXScrnSaver` |
| `libXss.so.1` | `libXScrnSaver` |

### Sandbox error / SUID sandbox

If you see errors about the sandbox:
```
[FATAL:zygote_host_impl_linux.cc] The SUID sandbox helper binary was found, but...
```

Either the `chrome-sandbox` binary lost its setuid bit (reinstall fixes this), or
add `--no-sandbox` as a workaround:
```bash
claude-desktop --no-sandbox
```

### Black/blank window on Wayland

Force X11 mode:
```bash
OZONE_PLATFORM=x11 claude-desktop
```

Or force Wayland explicitly:
```bash
claude-desktop --ozone-platform=wayland
```

### GPU/graphics issues

```bash
# Disable GPU acceleration
CLAUDE_DISABLE_GPU=1 claude-desktop
```

Or run with GPU disabled permanently by creating `~/.config/Claude/gpu-disabled`:
```bash
touch ~/.config/Claude/gpu-disabled
# Then edit /usr/bin/claude-desktop and add --disable-gpu to the exec line
```

## App crashes on startup with SIGILL

The bundled Electron binary requires certain CPU features (SSE4, AVX, etc.). If your
CPU is very old (pre-2013 era), the binary may not be compatible. This is an upstream
Electron limitation — no fix available.

## MCP / integrations not working

MCP config location:
```
~/.config/Claude/claude_desktop_config.json
```

If this file doesn't exist, create it:
```bash
mkdir -p ~/.config/Claude
cat > ~/.config/Claude/claude_desktop_config.json <<'EOF'
{
  "mcpServers": {}
}
EOF
```

## App data / profile location

```
~/.config/Claude/          # Config files
~/.config/Claude/logs/     # Application logs
```

## Reinstalling cleanly

```bash
# Remove
sudo dnf remove claude-desktop

# Clear user data (optional, destructive)
rm -rf ~/.config/Claude

# Reinstall
sudo dnf install ./claude-desktop-*.rpm
```

## Build failures

### `app.asar not found`

The upstream installer structure has changed. Check the `work/extracted/` directory manually:
```bash
find work/extracted -name "*.asar" 2>/dev/null
```

Update `extract-windows.sh` if the path has changed, then open a PR.

### `Could not detect version`

The redirect URL format changed. Use manual override:
```bash
./packaging/scripts/build-rpm.sh --version X.Y.Z
```

### Native bindings not found

The pipeline couldn't get Linux native bindings. Options:
1. Manually copy a `.node` file to `patches/runtime/` and re-run
2. Check `aaddrick/claude-desktop-debian` releases for a compatible binary
3. Open an issue

### rpmbuild fails

```bash
# Check the rpmbuild log
cat work/rpmbuild/BUILD/*/build.log 2>/dev/null || true

# Try a manual rpmbuild with verbose output
rpmbuild -ba --verbose \
  --define "_topdir $(pwd)/work/rpmbuild" \
  packaging/fedora/claude-desktop.spec
```
