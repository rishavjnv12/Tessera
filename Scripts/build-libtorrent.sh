#!/usr/bin/env bash
# Builds libtorrent-rasterbar + OpenSSL for macOS (arm64, x86_64), iOS device (arm64)
# and iOS simulator (arm64, x86_64), then packages:
#   Vendor/libtorrent.xcframework   static libtorrent + libssl + libcrypto per platform
#   Vendor/include/                 libtorrent, boost and openssl headers
#   Vendor/libtorrent.xcconfig      header paths + preprocessor defines consumers must use
#
# Usage: Scripts/build-libtorrent.sh [--clean]
set -euo pipefail

LIBTORRENT_VERSION=2.1.2
BOOST_VERSION=1.92.0
OPENSSL_VERSION=3.5.8
MACOS_MIN=14.0
IOS_MIN=17.0

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VENDOR="$ROOT/Vendor"
WORK="$VENDOR/.work"
SRC="$WORK/src"
JOBS="$(sysctl -n hw.ncpu)"

[[ "${1:-}" == "--clean" ]] && rm -rf "$WORK/build" "$WORK/install" "$VENDOR/libtorrent.xcframework" "$VENDOR/include"
mkdir -p "$SRC"

log() { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }

fetch() { # url
  local f="$SRC/$(basename "$1")"
  [[ -f "$f" ]] || curl -fsSL -o "$f" "$1"
  local d="${f%.tar.gz}"; d="${d%-b2-nodocs}"
  [[ -d "$d" ]] || tar xzf "$f" -C "$SRC"
}

log "Fetching sources"
fetch "https://github.com/arvidn/libtorrent/releases/download/v$LIBTORRENT_VERSION/libtorrent-rasterbar-$LIBTORRENT_VERSION.tar.gz"
fetch "https://github.com/boostorg/boost/releases/download/boost-$BOOST_VERSION/boost-$BOOST_VERSION-b2-nodocs.tar.gz"
fetch "https://github.com/openssl/openssl/releases/download/openssl-$OPENSSL_VERSION/openssl-$OPENSSL_VERSION.tar.gz"
LT_SRC="$SRC/libtorrent-rasterbar-$LIBTORRENT_VERSION"
BOOST_SRC="$SRC/boost-$BOOST_VERSION"
SSL_SRC="$SRC/openssl-$OPENSSL_VERSION"

# slice: name | sdk | arch | openssl target | min-version flag | cmake system name
SLICES=(
  "macos-arm64|macosx|arm64|darwin64-arm64-cc|-mmacosx-version-min=$MACOS_MIN|Darwin"
  "macos-x86_64|macosx|x86_64|darwin64-x86_64-cc|-mmacosx-version-min=$MACOS_MIN|Darwin"
  "ios-arm64|iphoneos|arm64|ios64-xcrun|-mios-version-min=$IOS_MIN|iOS"
  "sim-arm64|iphonesimulator|arm64|iossimulator-arm64-xcrun|-mios-simulator-version-min=$IOS_MIN|iOS"
  "sim-x86_64|iphonesimulator|x86_64|iossimulator-x86_64-xcrun|-mios-simulator-version-min=$IOS_MIN|iOS"
)

build_openssl() { # name sdk arch target minflag
  local name=$1 sdk=$2 arch=$3 target=$4 minflag=$5
  local prefix="$WORK/install/$name/openssl"
  [[ -f "$prefix/lib/libcrypto.a" ]] && { echo "openssl $name: cached"; return; }
  log "OpenSSL $OPENSSL_VERSION for $name"
  local b="$WORK/build/$name/openssl"; rm -rf "$b"; mkdir -p "$b"
  # The OpenSSL targets already pick the architecture and (via xcrun) the SDK.
  (cd "$b" && SDKROOT="$(xcrun --sdk "$sdk" --show-sdk-path)" \
    "$SSL_SRC/Configure" "$target" no-shared no-tests no-docs no-apps no-module no-engine no-ui-console \
      --prefix="$prefix" --openssldir=/etc/ssl --libdir=lib \
      "$minflag") >"$b.configure.log" 2>&1 || { cat "$b.configure.log"; exit 1; }
  SDKROOT="$(xcrun --sdk "$sdk" --show-sdk-path)" make -C "$b" -j"$JOBS" build_libs >"$b.build.log" 2>&1 || { tail -40 "$b.build.log"; exit 1; }
  make -C "$b" install_dev >/dev/null 2>&1
}

build_libtorrent() { # name sdk arch minflag system
  local name=$1 sdk=$2 arch=$3 system=$5
  local prefix="$WORK/install/$name/libtorrent"
  local ssl="$WORK/install/$name/openssl"
  [[ -f "$prefix/lib/libtorrent-rasterbar.a" ]] && { echo "libtorrent $name: cached"; return; }
  log "libtorrent $LIBTORRENT_VERSION for $name"
  local b="$WORK/build/$name/libtorrent"; rm -rf "$b"
  local min=$MACOS_MIN; [[ $system == iOS ]] && min=$IOS_MIN
  cmake -S "$LT_SRC" -B "$b" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_SYSTEM_NAME="$system" \
    -DCMAKE_OSX_SYSROOT="$sdk" \
    -DCMAKE_OSX_ARCHITECTURES="$arch" \
    -DCMAKE_OSX_DEPLOYMENT_TARGET="$min" \
    -DCMAKE_TRY_COMPILE_TARGET_TYPE=STATIC_LIBRARY \
    -DCMAKE_FIND_ROOT_PATH_MODE_INCLUDE=BOTH \
    -DCMAKE_FIND_ROOT_PATH_MODE_LIBRARY=BOTH \
    -DCMAKE_FIND_ROOT_PATH_MODE_PACKAGE=BOTH \
    -DCMAKE_POLICY_DEFAULT_CMP0167=OLD \
    -DCMAKE_CXX_STANDARD=17 \
    -DCMAKE_INSTALL_PREFIX="$prefix" \
    -DBUILD_SHARED_LIBS=OFF \
    -Dwebtorrent=OFF \
    -Dencryption=ON \
    -Ddeprecated-functions=OFF \
    -DBoost_INCLUDE_DIR="$BOOST_SRC" \
    -DBoost_NO_BOOST_CMAKE=ON \
    -DOPENSSL_ROOT_DIR="$ssl" \
    -DOPENSSL_INCLUDE_DIR="$ssl/include" \
    -DOPENSSL_SSL_LIBRARY="$ssl/lib/libssl.a" \
    -DOPENSSL_CRYPTO_LIBRARY="$ssl/lib/libcrypto.a" \
    -DOPENSSL_USE_STATIC_LIBS=ON >"$b.configure.log" 2>&1 || { cat "$b.configure.log"; exit 1; }
  cmake --build "$b" -j"$JOBS" >"$b.build.log" 2>&1 || { tail -60 "$b.build.log"; exit 1; }
  cmake --install "$b" >/dev/null
}

for s in "${SLICES[@]}"; do
  IFS='|' read -r name sdk arch target minflag system <<<"$s"
  build_openssl "$name" "$sdk" "$arch" "$target" "$minflag"
  build_libtorrent "$name" "$sdk" "$arch" "$minflag" "$system"
done

log "Merging static libraries"
merge() { # name -> combined .a
  local i="$WORK/install/$1"
  libtool -static -no_warning_for_no_symbols -o "$WORK/install/$1/libtorrent-combined.a" \
    "$i/libtorrent/lib/libtorrent-rasterbar.a" "$i/openssl/lib/libssl.a" "$i/openssl/lib/libcrypto.a"
}
for s in "${SLICES[@]}"; do merge "${s%%|*}"; done

U="$WORK/universal"; rm -rf "$U"; mkdir -p "$U/macos" "$U/ios" "$U/sim"
lipo -create "$WORK/install/macos-arm64/libtorrent-combined.a" "$WORK/install/macos-x86_64/libtorrent-combined.a" -output "$U/macos/libtorrent.a"
cp "$WORK/install/ios-arm64/libtorrent-combined.a" "$U/ios/libtorrent.a"
lipo -create "$WORK/install/sim-arm64/libtorrent-combined.a" "$WORK/install/sim-x86_64/libtorrent-combined.a" -output "$U/sim/libtorrent.a"

log "Creating libtorrent.xcframework"
rm -rf "$VENDOR/libtorrent.xcframework"
xcodebuild -create-xcframework \
  -library "$U/macos/libtorrent.a" \
  -library "$U/ios/libtorrent.a" \
  -library "$U/sim/libtorrent.a" \
  -output "$VENDOR/libtorrent.xcframework" >/dev/null

log "Installing headers"
rm -rf "$VENDOR/include"; mkdir -p "$VENDOR/include"
cp -R "$WORK/install/macos-arm64/libtorrent/include/libtorrent" "$VENDOR/include/"
cp -R "$WORK/install/macos-arm64/openssl/include/openssl" "$VENDOR/include/"
cp -R "$BOOST_SRC/boost" "$VENDOR/include/"

log "Writing libtorrent.xcconfig"
# Interface compile definitions exported by libtorrent's CMake package. Consumers must
# compile with exactly these or the ABI will not match the static library.
TARGETS_FILE="$(find "$WORK/install/macos-arm64/libtorrent/lib/cmake" -name 'LibtorrentRasterbarTargets.cmake' | head -1)"
DEFS="$(grep -E 'INTERFACE_COMPILE_DEFINITIONS' "$TARGETS_FILE" | head -1 | sed -E 's/.*"(.*)".*/\1/' | tr ';' '\n' | grep -v '\$<' | tr '\n' ' ' | sed 's/ $//')"
# Sanity check: every slice must export the same defines.
for s in "${SLICES[@]}"; do
  f="$(find "$WORK/install/${s%%|*}/libtorrent/lib/cmake" -name 'LibtorrentRasterbarTargets.cmake' | head -1)"
  d="$(grep -E 'INTERFACE_COMPILE_DEFINITIONS' "$f" | head -1 | sed -E 's/.*"(.*)".*/\1/' | tr ';' '\n' | grep -v '\$<' | tr '\n' ' ' | sed 's/ $//')"
  [[ "$d" == "$DEFS" ]] || { echo "Define mismatch in ${s%%|*}: $d"; exit 1; }
done
cat > "$VENDOR/libtorrent.xcconfig" <<XC
// Generated by Scripts/build-libtorrent.sh — do not edit.
// libtorrent $LIBTORRENT_VERSION, Boost $BOOST_VERSION, OpenSSL $OPENSSL_VERSION
LIBTORRENT_DEFINES = $DEFS
// System search path so warnings inside Boost and libtorrent headers are not reported.
SYSTEM_HEADER_SEARCH_PATHS = \$(inherited) \$(PROJECT_DIR)/Vendor/include
GCC_PREPROCESSOR_DEFINITIONS = \$(inherited) \$(LIBTORRENT_DEFINES)
XC
cat "$VENDOR/libtorrent.xcconfig"
log "Done"
