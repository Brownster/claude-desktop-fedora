# Architecture

## How the build pipeline works

Claude Desktop is an [Electron](https://www.electronjs.org/) application. Electron apps bundle
Chromium + Node.js and ship the application code in an `.asar` archive. The application logic
itself is cross-platform JavaScript. The only Windows-specific piece is the native bindings module.

### Pipeline stages

```
Official Windows installer
         │
         ▼
  download-upstream.sh
  ┌─────────────────────────────────────────────┐
  │ • Follows redirect to get versioned URL      │
  │ • Downloads Claude-X.Y.Z-x64.exe            │
  │ • Records SHA256 + upstream.json metadata   │
  └─────────────────────────────────────────────┘
         │
         ▼
  extract-windows.sh
  ┌─────────────────────────────────────────────┐
  │ • 7z extracts NSIS/Squirrel installer        │
  │ • Locates app.asar in extracted tree        │
  │ • @electron/asar unpacks app.asar → app/    │
  │ • Copies Electron runtime → electron/       │
  └─────────────────────────────────────────────┘
         │
         ▼
  patch-linux-runtime.sh
  ┌─────────────────────────────────────────────┐
  │ • Copies app/ → app-patched/                │
  │ • Replaces *.node (Windows) with Linux ELF  │
  │   Sources (in priority order):              │
  │     1. patches/runtime/ (pre-staged)        │
  │     2. aaddrick/claude-desktop-debian releases│
  │     3. npm (claude-native package)          │
  │ • Neutralizes Squirrel auto-updater         │
  │ • Patches any Windows-specific JS paths     │
  └─────────────────────────────────────────────┘
         │
         ▼
  make-source-tarball.sh
  ┌─────────────────────────────────────────────┐
  │ • Repacks app-patched/ → app.asar           │
  │ • Assembles staging tree:                   │
  │     claude-desktop-X.Y.Z/                  │
  │       <electron runtime (Linux)>           │
  │       resources/app.asar                   │
  │       resources/claude-desktop.sh          │
  │       resources/claude-desktop.desktop     │
  │       icons/                               │
  │       build-metadata.json                  │
  │ • Creates deterministic .tar.gz            │
  └─────────────────────────────────────────────┘
         │
         ▼
  rpmbuild (via build-rpm.sh)
  ┌─────────────────────────────────────────────┐
  │ • Reads claude-desktop.spec                 │
  │ • Installs files to buildroot               │
  │ • Produces .rpm + .src.rpm                  │
  └─────────────────────────────────────────────┘
         │
         ▼
  dist/claude-desktop-X.Y.Z-N.x86_64.rpm
```

### Installed layout

```
/opt/claude-desktop/          # Electron runtime + app
  claude                      # Electron binary (renamed)
  resources/
    app.asar                  # Application code
  chrome-sandbox              # setuid sandbox helper
  lib*.so                     # Bundled shared libs
  ...

/usr/bin/claude-desktop       # Launcher wrapper script
/usr/share/applications/claude-desktop.desktop
/usr/share/icons/hicolor/*/apps/claude-desktop.png
```

### Native bindings

The Windows installer contains a `*.node` (native Node.js addon) that provides OS-level
features. This binary is PE32+ (Windows only) and must be replaced with a Linux ELF build
for the same module before the app will start.

The replacement comes from the `aaddrick/claude-desktop-debian` project which maintains
Linux builds of this module. See `packaging/scripts/patch-linux-runtime.sh` for the
full replacement strategy.

### Fragile points

These are the most likely places where the pipeline will break when upstream changes:

1. **Installer structure** — If Anthropic changes from NSIS to another installer format,
   the 7z extraction step needs adjustment.

2. **app.asar path** — The path to `app.asar` within the installer may change.

3. **Native module name/path** — If the `.node` file is renamed or moved within the asar.

4. **Native module ABI** — If Electron is updated, the native module must be recompiled
   for the new Node ABI version.

When any of these break, the pipeline will fail loudly (not silently). Fix by updating
the relevant script and committing the change.
