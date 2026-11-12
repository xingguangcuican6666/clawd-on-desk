#!/usr/bin/env bash
set -euo pipefail

pacman -Syu --noconfirm --needed base-devel git nodejs npm python fakeroot \
  binutils findutils zstd pacman-contrib unzip libarchive

# GitHub runners export npm_config_* overrides (a mirror registry and a
# lockfile policy that rejects remote tarballs); clear them so the lockfile is
# installed exactly as written. allow-remote takes all, none or root.
unset npm_config_registry npm_config_userconfig npm_config_globalconfig \
      NPM_CONFIG_REGISTRY NPM_CONFIG_USERCONFIG NPM_CONFIG_GLOBALCONFIG
npm_config_allow_remote=all npm ci --ignore-scripts

# Electron postinstall cannot complete in this image, so fetch the dist
# explicitly; the app own integrity gate then validates the result.
node /work/ci/fetch-electron.js
npm run verify:electron

npx electron-builder --linux dir --x64 --publish never
test -x dist/linux-unpacked/clawd-on-desk
test -f dist/linux-unpacked/resources/app.asar

# Package ownership comes from the Arch file database.
pacman -Fy --noconfirm >/dev/null 2>&1 || true

buildroot=/work/.arch-build
rm -rf "$buildroot"
mkdir -p "$buildroot"
bash scripts/make-arch-pkgbuild.sh dist/linux-unpacked "$PKG_VERSION" "$buildroot/PKGBUILD"
# The payload lives next to the PKGBUILD, which reads it from startdir.
cp -a dist/linux-unpacked "$buildroot/app"
cp -a assets/icon.png "$buildroot/icon.png"
cp -a NOTICE.md "$buildroot/NOTICE.md"
if [[ -f LICENSE ]]; then cp -a LICENSE "$buildroot/LICENSE"; fi

# makepkg cannot run as root, so build as an unprivileged user.
id builder >/dev/null 2>&1 || useradd -m builder
chown -R builder "$buildroot"
su builder -c "cd '$buildroot' && makepkg --nodeps --noconfirm" 2>&1 | tail -20

pkg="$(ls -1 "$buildroot"/*.pkg.tar.zst | head -1)"
test -n "$pkg"
cp -a "$pkg" /work/out/
