# claude-desktop.spec — Unofficial Fedora RPM for Claude Desktop
#
# This spec consumes a prepared source tarball produced by make-source-tarball.sh
# The tarball layout:
#   claude-desktop-<version>/
#     <electron runtime files>
#     resources/app.asar
#     resources/claude-desktop.desktop
#     resources/claude-desktop.sh
#     icons/
#     build-metadata.json
#
# Build with:
#   rpmbuild -ba --define "upstream_version X.Y.Z" \
#                --define "rpm_release 1" \
#                claude-desktop.spec

%{!?upstream_version: %global upstream_version UNDEFINED}
%{!?rpm_release: %global rpm_release 1}

Name:           claude-desktop
Version:        %{upstream_version}
Release:        %{rpm_release}%{?dist}
Summary:        Claude Desktop — unofficial Fedora repackage

# The upstream application is proprietary. This spec and associated scripts are MIT.
License:        Proprietary
URL:            https://claude.ai
BuildArch:      x86_64

Source0:        %{name}-%{version}.tar.gz

# Electron runtime dependencies (validated via ldd on bundled binary)
Requires:       gtk3
Requires:       nss
Requires:       nspr
Requires:       atk
Requires:       libXcomposite
Requires:       libXcursor
Requires:       libXdamage
Requires:       libXext
Requires:       libXfixes
Requires:       libXi
Requires:       libXrandr
Requires:       libXrender
Requires:       libXtst
Requires:       libxcb
Requires:       libXScrnSaver
Requires:       alsa-lib
Requires:       cups-libs
Requires:       libdrm
Requires:       mesa-libgbm
Requires:       libgbm
Requires:       dbus-libs

# Optional but strongly recommended
Requires:       bubblewrap
Requires:       xdg-utils

# Prevent installation on non-x86_64
ExclusiveArch:  x86_64

%description
Unofficial Fedora RPM repackage of the proprietary Claude Desktop application
by Anthropic. This package is not supported by or affiliated with Anthropic.

The application is an Electron-based desktop client for Claude AI.

This package is produced by extracting the official Windows installer,
replacing Windows-only native components with Linux-compatible equivalents,
and repackaging as an RPM.

See: https://github.com/REPO_PLACEHOLDER for source and build scripts.

%prep
%autosetup -n %{name}-%{version}

%build
# Nothing to compile — all binaries are pre-built

%install
install -d %{buildroot}/opt/%{name}
install -d %{buildroot}%{_bindir}
install -d %{buildroot}%{_datadir}/applications
install -d %{buildroot}%{_datadir}/icons/hicolor/16x16/apps
install -d %{buildroot}%{_datadir}/icons/hicolor/32x32/apps
install -d %{buildroot}%{_datadir}/icons/hicolor/48x48/apps
install -d %{buildroot}%{_datadir}/icons/hicolor/64x64/apps
install -d %{buildroot}%{_datadir}/icons/hicolor/128x128/apps
install -d %{buildroot}%{_datadir}/icons/hicolor/256x256/apps
install -d %{buildroot}%{_datadir}/icons/hicolor/512x512/apps
install -d %{buildroot}%{_datadir}/icons/hicolor/scalable/apps

# Copy the full Electron app tree to /opt/claude-desktop
cp -r . %{buildroot}/opt/%{name}/

# Remove Windows-only files if they slipped through
find %{buildroot}/opt/%{name} -name "*.exe" -delete 2>/dev/null || true
find %{buildroot}/opt/%{name} -name "*.dll" -delete 2>/dev/null || true
find %{buildroot}/opt/%{name} -name "*.pdb" -delete 2>/dev/null || true

# Make the Electron binary executable and rename
if [ -f %{buildroot}/opt/%{name}/claude ]; then
    chmod 755 %{buildroot}/opt/%{name}/claude
elif [ -f %{buildroot}/opt/%{name}/Claude ]; then
    mv %{buildroot}/opt/%{name}/Claude %{buildroot}/opt/%{name}/claude
    chmod 755 %{buildroot}/opt/%{name}/claude
fi

# Mark setuid helper if present (needed for sandboxing)
if [ -f %{buildroot}/opt/%{name}/chrome-sandbox ]; then
    chmod 4755 %{buildroot}/opt/%{name}/chrome-sandbox
fi

# Install launcher wrapper
install -m 755 %{buildroot}/opt/%{name}/resources/claude-desktop.sh \
               %{buildroot}%{_bindir}/claude-desktop

# Install desktop entry
install -m 644 %{buildroot}/opt/%{name}/resources/claude-desktop.desktop \
               %{buildroot}%{_datadir}/applications/claude-desktop.desktop

# Validate the desktop file
desktop-file-validate %{buildroot}%{_datadir}/applications/claude-desktop.desktop || true

# Install icons (various sizes from the icons/ subdirectory)
for SIZE in 16 32 48 64 128 256 512; do
    if [ -f "%{buildroot}/opt/%{name}/icons/${SIZE}x${SIZE}.png" ]; then
        install -m 644 "%{buildroot}/opt/%{name}/icons/${SIZE}x${SIZE}.png" \
                       "%{buildroot}%{_datadir}/icons/hicolor/${SIZE}x${SIZE}/apps/claude-desktop.png"
    fi
done

# Scalable SVG if available
if [ -f "%{buildroot}/opt/%{name}/icons/claude-desktop.svg" ]; then
    install -m 644 "%{buildroot}/opt/%{name}/icons/claude-desktop.svg" \
                   "%{buildroot}%{_datadir}/icons/hicolor/scalable/apps/claude-desktop.svg"
fi

# Clean up icons/ staging directory from installed tree
rm -rf %{buildroot}/opt/%{name}/icons

# Set correct permissions on native modules
find %{buildroot}/opt/%{name} -name "*.node" -exec chmod 755 {} \;

# Strip unnecessary execute bits from data files
find %{buildroot}/opt/%{name}/resources -name "*.asar" -exec chmod 644 {} \;

%post
# Update icon cache and desktop database
/usr/bin/update-desktop-database %{_datadir}/applications &>/dev/null || true
/usr/bin/gtk-update-icon-cache -f -t %{_datadir}/icons/hicolor &>/dev/null || true

%postun
/usr/bin/update-desktop-database %{_datadir}/applications &>/dev/null || true
/usr/bin/gtk-update-icon-cache -f -t %{_datadir}/icons/hicolor &>/dev/null || true

%files
%license build-metadata.json
/opt/%{name}/
%{_bindir}/claude-desktop
%{_datadir}/applications/claude-desktop.desktop
%{_datadir}/icons/hicolor/*/apps/claude-desktop.*

%changelog
* Wed Apr 09 2026 Unofficial Packager <noreply@example.com> - %{upstream_version}-%{rpm_release}
- Automated packaging of Claude Desktop %{upstream_version} for Fedora
