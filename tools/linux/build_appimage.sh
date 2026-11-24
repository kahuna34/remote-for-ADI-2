#!/usr/bin/env bash
set -euo pipefail

if [[ $# != 0 ]]; then
  echo "Usage: $0" >&2
  exit 2
fi
if [[ $(uname -s) != Linux || $(uname -m) != x86_64 ]]; then
  echo 'Build on Linux x86_64 (Linux Mint 22 / Ubuntu 24.04).' >&2
  exit 1
fi

repo=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
project="$repo/host"
binary=adi2_host
name='Remote for ADI-2'
id=de.markus.adi2_remote_host
prefix=Remote-for-ADI-2
icon="$repo/assets/images/app_icon.png"
flutter_bin=${FLUTTER:-flutter}
appimagetool=${APPIMAGETOOL:-appimagetool}
command -v "$flutter_bin" >/dev/null || { echo 'Flutter not found (set FLUTTER).' >&2; exit 1; }
command -v "$appimagetool" >/dev/null || { echo 'appimagetool not found (set APPIMAGETOOL); nothing is downloaded.' >&2; exit 1; }
version=$(sed -nE 's/^version:[[:space:]]*([0-9]+\.[0-9]+\.[0-9]+).*/\1/p' "$repo/pubspec.yaml")
build_number=$(sed -nE 's/^version:.*\+([0-9]+).*/\1/p' "$repo/pubspec.yaml")
[[ -n $version && -n $build_number ]] || { echo 'Version missing in pubspec.yaml.' >&2; exit 1; }

cd -- "$project"
"$flutter_bin" pub get
"$flutter_bin" build linux --release --target-platform linux-x64 --build-name="$version" --build-number="$build_number"
bundle="$project/build/linux/x64/release/bundle"
[[ -x "$bundle/$binary" ]] || { echo "Bundle missing: $bundle/$binary" >&2; exit 1; }
work=$(mktemp -d "${TMPDIR:-/tmp}/adi2-appimage.XXXXXX")
trap 'rm -rf -- "$work"' EXIT
appdir="$work/$binary.AppDir"
mkdir -p "$appdir/usr" "$repo/dist"
cp -a "$bundle/." "$appdir/usr/"
cp -- "$icon" "$appdir/$id.png"
cp -- "$icon" "$appdir/.DirIcon"
cat > "$appdir/AppRun" <<EOF
#!/bin/sh
appdir=\$(CDPATH= cd -- "\$(dirname -- "\$0")" && pwd)
export LD_LIBRARY_PATH="\$appdir/usr/lib\${LD_LIBRARY_PATH:+:\$LD_LIBRARY_PATH}"
exec "\$appdir/usr/$binary" "\$@"
EOF
chmod +x "$appdir/AppRun"
cat > "$appdir/$id.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=$name
Exec=AppRun
Icon=$id
Terminal=false
Categories=AudioVideo;Audio;
StartupWMClass=$id
EOF
ARCH=x86_64 "$appimagetool" "$appdir" "$repo/dist/$prefix-Linux-$version.AppImage"
echo "Created: $repo/dist/$prefix-Linux-$version.AppImage"
