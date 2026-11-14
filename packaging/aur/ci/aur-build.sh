#!/usr/bin/env bash
# Build and verify the AUR package inside an Arch container.
#
# Called by .github/workflows/publish-aur.yml. Expects /work to be the checkout
# with aur-input/ (the downloaded release AppImage plus SHA256SUMS) and
# packaging/aur/clawd-on-desk-bin/PKGBUILD already staged for the release.
#
# The checks here are the ones a wrong package actually fails:
#   - the package builds at all, with the repository's own checksums
#   - .PKGINFO carries the version, architecture and license the AUR entry claims
#   - the runtime dependencies the shipped binary needs are declared
#   - the installed layout has the launcher, desktop entry, icons and the
#     setuid sandbox helper, and pacman can install it into a clean root
set -euo pipefail

# The container runs as root and needs the toolchain installed. A local run is
# an unprivileged user on an Arch host that already has it, so this is skipped
# rather than failing on pacman's root check.
if [[ $EUID -eq 0 ]]; then
  pacman -Syu --noconfirm --needed base-devel git python fakeroot binutils \
    findutils zstd libarchive openssh >/dev/null
fi

work="${AUR_WORK:-/work}"
pkgdir="$work/packaging/aur/clawd-on-desk-bin"
out="$work/out/aur"
buildroot=/tmp/aur-build

# Reuse the exact sources the workflow measured rather than re-downloading:
# the checksum in the PKGBUILD was computed from this file.
rm -rf "$buildroot"
mkdir -p "$buildroot/src" "$out"
cp "$pkgdir/PKGBUILD" "$buildroot/PKGBUILD"
version="$(sed -n 's/^pkgver=//p' "$buildroot/PKGBUILD")"
cp "$work/aur-input/Clawd-on-Desk-${version}-x86_64.AppImage" "$buildroot/src/"
# The license files come from the same tag; fetch them so their checksums in
# the PKGBUILD are verified rather than skipped.
curl -fsSL --retry 5 --retry-all-errors \
  -o "$buildroot/src/LICENSE" \
  "https://raw.githubusercontent.com/rullerzhou-afk/clawd-on-desk/v${version}/LICENSE"
curl -fsSL --retry 5 --retry-all-errors \
  -o "$buildroot/src/NOTICE.md" \
  "https://raw.githubusercontent.com/rullerzhou-afk/clawd-on-desk/v${version}/NOTICE.md"

# makepkg refuses to run as root; build as an unprivileged user. In the
# container that user has to be created; a local run already is one, and su
# would prompt for a password there, so it is only used when root.
if [[ $EUID -eq 0 ]]; then
  id builder >/dev/null 2>&1 || useradd -m builder
  chown -R builder "$buildroot"
  run_makepkg() { su builder -c "cd '$buildroot' && makepkg $*"; }
else
  run_makepkg() { ( cd "$buildroot" && makepkg "$@" ); }
fi
# --nodeps: the dependency list is verified below from .PKGINFO instead. A
# missing dependency must fail this workflow with the name of the package, not
# with pacman's "could not satisfy dependencies" during an unrelated install.
run_makepkg --nodeps --noconfirm 2>&1 | tail -20

pkg="$(ls -1 "$buildroot"/*.pkg.tar.zst | head -1)"
test -n "$pkg"

info="$(bsdtar -xOf "$pkg" .PKGINFO)"
printf '%s\n' "$info" | head -20
printf '%s\n' "$info" | grep -qx "pkgname = clawd-on-desk-bin"
printf '%s\n' "$info" | grep -qx "arch = x86_64"
printf '%s\n' "$info" | grep -qx "pkgver = ${version}-1"
printf '%s\n' "$info" | grep -qx "license = AGPL-3.0-only"

# Every dependency the binary needs must be declared. This list is derived from
# the shipped binary, so a release that starts linking a new library fails here
# instead of at a user's first launch.
for dep in gtk3 nss nspr alsa-lib libx11 libxcb wayland libdrm mesa libnotify \
           libsecret libpulse libcups at-spi2-core pango glib2 dbus expat; do
  printf '%s\n' "$info" | grep -qx "depend = $dep" \
    || { echo "::error::${dep} missing from the depends list"; exit 1; }
done
# Bundle-provided libraries must not be requested from the distro.
if printf '%s\n' "$info" | grep -qE "^depend = (libegl|libgles|libffmpeg|libvulkan\.so)"; then
  echo "::error::bundle-provided libraries leaked into depends"; exit 1
fi

bsdtar -tf "$pkg" > /tmp/files.txt
for path in \
  opt/Clawd-on-Desk/clawd-on-desk \
  opt/Clawd-on-Desk/chrome-sandbox \
  opt/Clawd-on-Desk/resources/app.asar \
  usr/bin/clawd-on-desk \
  usr/share/applications/clawd-on-desk.desktop \
  usr/share/icons/hicolor/512x512/apps/clawd-on-desk.png \
  usr/share/licenses/clawd-on-desk-bin/LICENSE \
  usr/share/licenses/clawd-on-desk-bin/NOTICE.md; do
  grep -qx "$path" /tmp/files.txt \
    || { echo "::error::missing /$path in the package"; exit 1; }
done
# AppImage runtime leftovers: a mounted AppDir's launcher must not be installed
# as if it were a system launcher, and the bundled Ubuntu libraries would
# shadow the distro's if anything ever put /opt/.../usr/lib on the search path.
for path in opt/Clawd-on-Desk/AppRun opt/Clawd-on-Desk/clawd-appimage-launcher.sh; do
  if grep -qx "$path" /tmp/files.txt; then
    echo "::error::AppImage runtime file /$path leaked into the package"; exit 1
  fi
done
if grep -q "^opt/Clawd-on-Desk/usr/" /tmp/files.txt; then
  echo "::error::bundled Ubuntu libraries leaked into the package"; exit 1
fi

# Install into a clean root: proves pacman accepts the metadata and that the
# setuid helper keeps its mode. Dependencies are skipped for the same reason as
# above; the declared list was checked already.
testroot=/tmp/pkgroot
rm -rf "$testroot"
mkdir -p "$testroot/var/lib/pacman"
fakeroot pacman -U --root "$testroot" --dbpath "$testroot/var/lib/pacman" \
  -dd --noconfirm "$pkg" >/dev/null
[[ "$(stat -c '%a' "$testroot/opt/Clawd-on-Desk/chrome-sandbox")" == "4755" ]] \
  || { echo "::error::chrome-sandbox lost its setuid mode"; exit 1; }
[[ "$(readlink "$testroot/usr/bin/clawd-on-desk")" == "/opt/Clawd-on-Desk/clawd-on-desk" ]] \
  || { echo "::error::/usr/bin launcher points somewhere unexpected"; exit 1; }
grep -qx "StartupWMClass=clawd-on-desk" "$testroot/usr/share/applications/clawd-on-desk.desktop" \
  || { echo "::error::desktop entry StartupWMClass does not match the app's window class"; exit 1; }

# The binary must not have a missing soname in the container that just built
# it: that is the difference between "depends list is right" and "depends list
# happens to look right".
missing="$(ldd "$testroot/opt/Clawd-on-Desk/clawd-on-desk" 2>&1 | grep -i 'not found' || true)"
if [[ -n "$missing" ]]; then
  echo "::error::unresolved shared libraries:"; printf '%s\n' "$missing"; exit 1
fi

# .SRCINFO is generated by makepkg, never hand-written: the AUR hook compares it
# against the PKGBUILD and rejects the push when they disagree.
run_makepkg --printsrcinfo > "$buildroot/.SRCINFO"
grep -qx "pkgbase = clawd-on-desk-bin" "$buildroot/.SRCINFO"

# Copied out as "SRCINFO" without the dot: upload-artifact v4 skips hidden files
# by default, and the workflow renames it back when it builds the commit.
cp "$pkg" "$buildroot/PKGBUILD" "$buildroot/.SRCINFO" "$out/"
mv "$out/.SRCINFO" "$out/SRCINFO"
echo "PASS: built and verified $pkg"
