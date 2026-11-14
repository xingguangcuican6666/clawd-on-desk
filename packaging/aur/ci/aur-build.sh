#!/usr/bin/env bash
# Build and verify an AUR package inside an Arch container.
#
# Called by .github/workflows/publish-aur.yml with AUR_PACKAGE naming which one:
#   clawd-on-desk-bin  repackages the release AppImage from aur-input/
#   clawd-on-desk-git  clones the fork's Wayland branch and builds from source
#
# The checks here are the ones a wrong package actually fails:
#   - the package builds at all
#   - .PKGINFO carries the name, architecture, version and license it claims
#   - the runtime dependencies the shipped binary needs are declared
#   - the installed layout has the launcher, desktop entry, icons and the
#     setuid sandbox helper, and pacman can install it into a clean root
set -euo pipefail

pkgname="${AUR_PACKAGE:-clawd-on-desk-bin}"

# The container runs as root and needs the toolchain installed. A local run is
# an unprivileged user on an Arch host that already has it, so this is skipped
# rather than failing on pacman's root check.
if [[ $EUID -eq 0 ]]; then
  pacman -Syu --noconfirm --needed base-devel git python fakeroot binutils \
    findutils zstd libarchive openssh nodejs npm >/dev/null
fi

work="${AUR_WORK:-/work}"
pkgdir="$work/packaging/aur/$pkgname"
out="$work/out/aur"
buildroot=/tmp/aur-build

rm -rf "$buildroot"
mkdir -p "$buildroot/src" "$out"
cp "$pkgdir/PKGBUILD" "$buildroot/PKGBUILD"

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

if [[ "$pkgname" == "clawd-on-desk-bin" ]]; then
  # Reuse the exact sources the workflow measured rather than re-downloading:
  # the checksum in the PKGBUILD was computed from this file.
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
fi
# The -git package pre-stages nothing: makepkg clones the branch itself and
# pkgver() derives the version from `git describe`, so the build also proves the
# source URL and branch in the PKGBUILD actually resolve.

# --nodeps for both: makepkg installs missing dependencies through pacman,
# which needs root, and the build runs as `builder`. The toolchain is installed
# as root above and the declared runtime dependencies are checked against the
# sync database below, so nothing is silently skipped.
run_makepkg --nodeps --noconfirm 2>&1 | tail -30

pkg="$(ls -1 "$buildroot"/*.pkg.tar.zst | head -1)"
test -n "$pkg"

info="$(bsdtar -xOf "$pkg" .PKGINFO)"
printf '%s\n' "$info" | head -20
printf '%s\n' "$info" | grep -qx "pkgname = $pkgname"
printf '%s\n' "$info" | grep -qx "arch = x86_64"
printf '%s\n' "$info" | grep -qx "license = AGPL-3.0-only"
if [[ "$pkgname" == "clawd-on-desk-bin" ]]; then
  printf '%s\n' "$info" | grep -qx "pkgver = ${version}-1"
else
  # The version comes from `git describe`; assert the shape rather than a value
  # that moves with every commit.
  printf '%s\n' "$info" | grep -qE "^pkgver = [0-9]+\.[0-9]+\.[0-9]+\.r[0-9]+\.g[0-9a-f]{7}(-[0-9]+)?$" \
    || { echo "::error::pkgver() did not produce an r<count>.g<sha> version"; exit 1; }
fi

# Every dependency the binary needs must be declared. This list is derived from
# the shipped binary, so a release that starts linking a new library fails here
# instead of at a user's first launch.
for dep in gtk3 nss nspr alsa-lib libx11 libxcb wayland libdrm mesa libnotify \
           libsecret libpulse libcups at-spi2-core pango glib2 dbus expat; do
  printf '%s\n' "$info" | grep -qx "depend = $dep" \
    || { echo "::error::${dep} missing from the depends list"; exit 1; }
done
# --nodeps means makepkg never resolved these, so name a dependency the repos do
# not actually provide here rather than letting a user's pacman discover it.
if [[ $EUID -eq 0 ]]; then
  while read -r dep; do
    pacman -Si -- "$dep" >/dev/null 2>&1 \
      || { echo "::error::declared dependency '$dep' is not in the Arch repos"; exit 1; }
  done < <(printf '%s\n' "$info" | sed -n 's/^depend = //p')
fi
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
  "usr/share/licenses/$pkgname/LICENSE" \
  "usr/share/licenses/$pkgname/NOTICE.md"; do
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

# The -git package is only worth publishing if the code it built is the branch
# this workflow claims to track. The Wayland backend files are the reason the
# package exists, so their presence in the asar is the assertion.
if [[ "$pkgname" == "clawd-on-desk-git" ]]; then
  bsdtar -xOf "$pkg" opt/Clawd-on-Desk/resources/app.asar > /tmp/app.asar
  if ! grep -qa "linux-wayland-shim" /tmp/app.asar; then
    echo "::error::the built asar does not contain the native Wayland backend"; exit 1
  fi
  echo "PASS: the asar carries src/linux-wayland-shim.js"
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
#
# makepkg rewrites the PKGBUILD's pkgver in place when pkgver() returns a new
# value ("已升级版本" in its output), so `--printsrcinfo` here already reports the
# version that was built rather than the static placeholder in the repository.
run_makepkg --printsrcinfo > "$buildroot/.SRCINFO"
grep -qx "pkgbase = $pkgname" "$buildroot/.SRCINFO"
if [[ "$pkgname" == "clawd-on-desk-git" ]]; then
  # If this ever diverges, the AUR page would advertise a version nobody builds.
  built_version="$(printf '%s\n' "$info" | sed -n 's/^pkgver = //p')"
  built_version="${built_version%-*}"
  grep -qx "	pkgver = ${built_version}" "$buildroot/.SRCINFO" \
    || { echo "::error::.SRCINFO pkgver does not match the built package"; exit 1; }
fi

# Copied out as "SRCINFO" without the dot: upload-artifact v4 skips hidden files
# by default, and the workflow renames it back when it builds the commit.
cp "$pkg" "$buildroot/PKGBUILD" "$buildroot/.SRCINFO" "$out/"
mv "$out/.SRCINFO" "$out/SRCINFO"
echo "PASS: built and verified $pkg"
