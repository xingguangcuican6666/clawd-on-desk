#!/usr/bin/env bash
# Generate an Arch Linux PKGBUILD for the unpacked electron-builder app.
#
# Usage: scripts/make-arch-pkgbuild.sh <app-dir> <version> <output-pkgbuild>
#
# Original work by xingguangcuican6666.
#
# Runtime dependencies are resolved from the binaries actually shipped: ldd
# supplies the sonames that are already linked, the dlopen()ed Electron
# runtime (GTK 3, NSS, X11, Wayland, GBM, ALSA) is listed explicitly, and
# `pacman -F` names the owning package. Libraries that ship inside the bundle
# are excluded — the distro must not be asked to provide them.
set -euo pipefail

appdir="${1:?usage: make-arch-pkgbuild.sh <app-dir> <version> <output>}"
version="${2:?missing version}"
output="${3:?missing output path}"

[[ -d "$appdir" ]] || { echo "error: $appdir is not a directory" >&2; exit 1; }
# pacman versions may not contain '-' or '+'.
version="${version#v}"
version="${version//-/}"
version="${version//+/}"

# ── runtime sonames ────────────────────────────────────────────────────────
# `ldd` prints "=> not found" without a path, so only resolved entries are
# collected; unresolved ones come from the explicit list below.
sonames="$(find "$appdir" -maxdepth 3 -type f \
    \( -name 'clawd-on-desk' -o -name '*.node' -o -path '*resources/*' \) -print0 2>/dev/null \
  | xargs -0 -r -I{} sh -c 'ldd "{}" 2>/dev/null || true' \
  | sed -n -e 's/.*=> \(.*\) (0x[0-9a-f]*)$/\1/p' -e 's/^[[:space:]]*\([^ ]*\.so[^ ]*\) (0x[0-9a-f]*)$/\1/p' \
  | xargs -r -n1 basename 2>/dev/null | sort -u || true)"

# Libraries Electron dlopen()s at runtime never appear in ldd output.
runtime_libs="
  libgtk-3.so.0 libgdk-3.so.0 libgdk_pixbuf-2.0.so.0
  libnss3.so libnspr4.so libsmime3.so
  libX11.so.6 libX11-xcb.so.1 libXcomposite.so.1 libXdamage.so.1
  libXext.so.6 libXfixes.so.3 libXrandr.so.2 libXrender.so.1 libXtst.so.6
  libxcb.so.1 libxkbcommon.so.0 libxkbcommon-x11.so.0
  libwayland-client.so.0 libwayland-cursor.so.0 libwayland-egl.so.1
  libdrm.so.2 libgbm.so.1 libGL.so.1 libvulkan.so.1 libasound.so.2
  libcups.so.2 libpulse.so.0 libatk-1.0.so.0 libatk-bridge-2.0.so.0
  libdbus-1.so.3 libsecret-1.so.0 libnotify.so.4 libglib-2.0.so.0
  libfontconfig.so.1 libfreetype.so.6
"
# Shipped inside the Electron bundle: never request them from the distro.
bundled="libEGL.so.1 libGLESv2.so.2 libffmpeg.so libvk_swiftshader.so"

deps="$( {
    printf '%s\n' $sonames
    printf '%s\n' $runtime_libs
  } | sed '/^$/d' | sort -u \
  | while IFS= read -r so; do
      skip=0
      for b in $bundled; do [[ "$so" == "$b" ]] && skip=1; done
      (( skip )) && continue
      # glibc is explicit below (ldd reports it as libc/ld-linux variants).
      # `pacman -Fq` answers "<repo>/<package>"; the PKGBUILD wants the bare name.
      pacman -Fq "usr/lib/$so" 2>/dev/null | head -1 | sed -e 's| .*||' -e 's|^.*/||'
    done | sed '/^$/d' | sort -u || true)"

# Always required, regardless of what ldd happened to resolve.
deps="$( { printf '%s\n' $deps; printf '%s\n' glibc gcc-libs; } | sed '/^$/d' | sort -u )"

if [[ -z "$deps" ]]; then
  echo "error: could not resolve any runtime dependency (is the pacman file database synced? run 'pacman -Fy')" >&2
  exit 1
fi

{
  echo "pkgname=clawd-on-desk"
  echo "pkgver=$version"
  echo "pkgrel=1"
  echo 'pkgdesc="Clawd on Desk - a desktop pet that reacts to your coding sessions"'
  echo "arch=('x86_64')"
  echo 'url="https://github.com/rullerzhou-afk/clawd-on-desk"'
  echo "license=('custom')"
  printf 'depends=('
  printf "'%s' " $deps
  echo ')'
  echo "options=('!strip' '!debug')"
  # No `source` entries: the payload sits next to the PKGBUILD and a
  # directory cannot be a source entry (makepkg refuses to copy a directory
  # it does not treat as an archive). package() reads it directly from
  # $startdir, which is the PKGBUILD's own directory.
  echo "source=()"
  echo "sha256sums=()"
  cat <<'PKGBODY'

package() {
  install -d "$pkgdir/opt" "$pkgdir/usr/bin" "$pkgdir/usr/share/applications" \
    "$pkgdir/usr/share/icons/hicolor/512x512/apps" \
    "$pkgdir/usr/share/licenses/$pkgname"

  cp -a "$startdir/app/." "$pkgdir/opt/Clawd-on-Desk/"

  # Chromium's setuid sandbox helper must stay root-owned and setuid; pacman
  # keeps the mode, so set both explicitly.
  chown -R root:root "$pkgdir"
  chmod 4755 "$pkgdir/opt/Clawd-on-Desk/chrome-sandbox"

  ln -s /opt/Clawd-on-Desk/clawd-on-desk "$pkgdir/usr/bin/clawd-on-desk"

  cat > "$pkgdir/usr/share/applications/clawd-on-desk.desktop" <<DESKTOP
[Desktop Entry]
Name=Clawd on Desk
Comment=A desktop pet that reacts to your coding sessions
Exec=/opt/Clawd-on-Desk/clawd-on-desk %U
Icon=clawd-on-desk
Type=Application
Categories=Utility;
StartupWMClass=clawd-on-desk
DESKTOP

  install -m 644 "$startdir/icon.png" \
    "$pkgdir/usr/share/icons/hicolor/512x512/apps/clawd-on-desk.png"
  install -m 644 "$startdir/NOTICE.md" "$pkgdir/usr/share/licenses/$pkgname/NOTICE.md"
  if [[ -f "$startdir/LICENSE" ]]; then
    install -m 644 "$startdir/LICENSE" "$pkgdir/usr/share/licenses/$pkgname/LICENSE"
  fi
}
PKGBODY
} > "$output"

echo "wrote $output (depends: $(printf '%s ' $deps))"
