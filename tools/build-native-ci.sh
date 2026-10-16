#!/bin/bash
# Build the actual app and native libraries. Run on macOS with Xcode 26+.
# No Apple certificate, provisioning profile, or Apple account is used.
set -euo pipefail
R="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$R"
export GITHUB_WORKSPACE="$R"
N="${JOBS:-$(sysctl -n hw.ncpu)}"
LOG="$R/build-out/logs"
mkdir -p "$LOG" toolchains
trap 'echo "Build stage failed at line $LINENO; see build-out/logs" >&2' ERR

run_log() {
    local name="$1"; shift
    "$@" > "$LOG/$name.log" 2>&1 || {
        tail -100 "$LOG/$name.log"
        return 1
    }
}

fetch_git() {
    local url="$1" rev="$2" dest="$3"
    if [ ! -d "$dest/.git" ]; then
        git init "$dest"
        git -C "$dest" remote add origin "$url"
        git -C "$dest" fetch --depth 1 origin "$rev"
        git -C "$dest" checkout --detach FETCH_HEAD
    fi
    [ "$(git -C "$dest" rev-parse HEAD)" = "$rev" ] || {
        echo "Source revision mismatch in $dest" >&2; exit 1;
    }
}

prepare() {
    python3 tools/build-native-ci.py
    (cd build/gnutls-ios/src && shasum -a 256 -c SHA256SUMS)
    bash build/madeira-d3d12/deps.sh
    fetch_git https://github.com/freetype/freetype.git \
        42608f77f20749dd6ddc9e0536788eaad70ea4b5 research/freetype
}

mingw() {
    local name=llvm-mingw-20260421-ucrt-macos-universal
    if [ ! -x "toolchains/$name/bin/x86_64-w64-mingw32-clang" ]; then
        curl -fL --retry 4 -o "$LOG/llvm-mingw.tar.xz" \
            "https://github.com/mstorsjo/llvm-mingw/releases/download/20260421/$name.tar.xz"
        echo "bd85a3975723815cef28dbbd2ca2cb0c926f6b348a12a0453f39f7af273cb3f7  $LOG/llvm-mingw.tar.xz" | shasum -a 256 -c -
        tar -xJf "$LOG/llvm-mingw.tar.xz" -C toolchains
    fi
}

wine() {
    mkdir -p wine/build-native wine/build-macos
    if [ ! -x wine/build-native/tools/widl/widl ]; then
        (cd wine/build-native && run_log wine-native-configure ../configure --enable-win64 --disable-tests --without-x)
        run_log wine-native-tools make -C wine/build-native -j"$N" \
            tools/widl/widl tools/wrc/wrc tools/wmc/wmc tools/winebuild/winebuild
        run_log wine-native-headers make -C wine/build-native -j"$N" include
    fi
    test -x wine/build-native/tools/widl/widl
    (cd wine/build-macos && run_log wine-configure ../configure \
        --enable-win64 --disable-tests \
        CC="xcrun -sdk iphoneos clang -arch arm64 -miphoneos-version-min=17.0" \
        CROSSCC="xcrun -sdk iphoneos clang -arch arm64 -miphoneos-version-min=17.0" \
        --host=aarch64-apple-darwin --build="$(uname -m)-apple-darwin" \
        --with-wine-tools="$R/wine/build-native" \
        --without-freetype --without-fontconfig --without-x --without-opengl \
        --without-vulkan --without-gnutls --without-pcsclite --without-usb \
        --without-v4l2 --without-gphoto --without-inotify --without-sane \
        --without-pulse --without-alsa --without-oss --without-capi --without-cups \
        --without-krb5 --without-ldap --without-netapi --without-sdl --without-udev --without-unwind)
    run_log wine-headers make -C wine/build-macos -j"$N" include
    cp -n wine/build-native/include/*.h wine/build-macos/include/ || true
    cat >> wine/build-macos/include/config.h <<'EOF'
/* iOS SDK + statically linked GnuTLS, used by Madeira's Unix shims. */
#undef HAVE_GETATTRLIST
#ifndef D_TAPE
#define D_TAPE 1
#define D_DISK 2
#define D_TTY 3
#endif
#ifndef SONAME_LIBGNUTLS
#define SONAME_LIBGNUTLS "libgnutls.so.30"
#endif
#ifndef HAVE_GNUTLS_CIPHER_INIT
#define HAVE_GNUTLS_CIPHER_INIT 1
#endif
EOF
    run_log freetype bash build/freetype-ios/build.sh
    run_log gnutls bash build/gnutls-ios/build.sh
    run_log ffmpeg bash build/ffmpeg/build.sh
    run_log ntdll bash build/ntdll-unix/build.sh
    # Upstream's wineserver script replaces objects in a development archive.
    # Build every base object from source first; omitted platform-specific
    # files must have an explicit replacement in the upstream script.
    python3 - <<'PY'
from pathlib import Path
import re, subprocess, os
r = Path.cwd()
b = r / 'build/wineserver'
out = b / 'obj/base'
out.mkdir(parents=True, exist_ok=True)
sdk = subprocess.check_output(['xcrun', '--sdk', 'iphoneos', '--show-sdk-path'], text=True).strip()
flags = ['-arch','arm64','-isysroot',sdk,'-miphoneos-version-min=17.0','-O2',
         '-D__WINESRC__','-DWINE_IOS=1','-Dmain=wineserver_main','-DHAVE_LINUX_NTSYNC_H=1',
         '-DBINDIR="/usr/local/bin"','-DDATADIR="/usr/local/share"','-Wno-implicit-function-declaration']
for p in ['wine/include','wine/include/wine','wine/build-macos/include','build/wineserver',
          'wine/server','build/ntdll-unix/shims','build/madsync']:
    flags += ['-I' + str(r / p)]
for p in [str(b/'config_ios.h'),'stdarg.h',str(b/'unicode_fix.h'),str(b/'wineserver_ios_kill.h')]:
    flags += ['-include',p]
script = (b/'build.sh').read_text()
replaced = set(re.findall(r'"[^"\n:]+:([\w]+)\.o"', script))
for source in sorted((r/'wine/server').glob('*.c')):
    obj = out/(source.stem + '.o')
    with (out/(source.stem + '.err')).open('w') as log:
        rc = subprocess.run(['xcrun','-sdk','iphoneos','clang',*flags,'-c',str(source),'-o',str(obj)], stderr=log).returncode
    if rc and source.stem not in replaced:
        raise SystemExit(f'Base wineserver failed for unreplaced source {source}: {(out/(source.stem + ".err")).read_text()}')
    print(source.name, 'replaced by upstream iOS source' if rc else 'compiled')
subprocess.run(['ar','rcs',str(b/'obj/libwineserver.a'),*map(str,out.glob('*.o'))], check=True)
PY
    run_log wineserver bash build/wineserver/build.sh
    run_log win32u bash build/win32u-unix/build.sh
}

fex() {
    run_log fex-configure cmake -S FEX -B FEX/build-ios -G Ninja \
        -DCMAKE_SYSTEM_NAME=iOS -DCMAKE_SYSTEM_PROCESSOR=aarch64 \
        -DCMAKE_OSX_SYSROOT="$(xcrun --sdk iphoneos --show-sdk-path)" \
        -DCMAKE_OSX_ARCHITECTURES=arm64 -DCMAKE_OSX_DEPLOYMENT_TARGET=17.0 \
        -DCMAKE_BUILD_TYPE=Release -DCMAKE_MACOSX_BUNDLE=OFF \
        -DBUILD_TESTING=OFF -DBUILD_FEXCONFIG=OFF -DBUILD_THUNKS=OFF \
        -DBUILD_FEX_LINUX_TESTS=OFF -DENABLE_LTO=OFF -DENABLE_CCACHE=OFF \
        -DENABLE_FEX_ALLOCATOR=OFF -DTUNE_CPU=generic -DTUNE_ARCH=generic \
        -DCMAKE_DISABLE_FIND_PACKAGE_fmt=ON
    run_log fex-build cmake --build FEX/build-ios -j"$N" \
        --target FEXCore FEXCore_Base JemallocLibs cephes_128bit softfloat_3e fmt xxhash
}

llvm() {
    fetch_git https://github.com/llvm/llvm-project.git \
        8dfdcc7b7bf66834a761bd8de445840ef68e4d1a toolchains/llvm-project
    sed -i '' 's/MATCHES "Darwin"/MATCHES "Darwin|iOS"/' toolchains/llvm-project/llvm/cmake/modules/AddLLVM.cmake
    run_log llvm-host-configure cmake -S toolchains/llvm-project/llvm -B toolchains/llvm-host-build -G Ninja \
        -DCMAKE_BUILD_TYPE=Release -DCMAKE_C_COMPILER=/usr/bin/clang -DCMAKE_CXX_COMPILER=/usr/bin/clang++ \
        -DLLVM_TARGETS_TO_BUILD= -DLLVM_INCLUDE_TESTS=Off -DLLVM_INCLUDE_EXAMPLES=Off -DLLVM_INCLUDE_BENCHMARKS=Off
    run_log llvm-host-build cmake --build toolchains/llvm-host-build --target llvm-tblgen -j"$N"
    run_log llvm-ios-configure cmake -S toolchains/llvm-project/llvm -B toolchains/llvm-ios-build -G Ninja \
        -DCMAKE_SYSTEM_NAME=iOS -DCMAKE_OSX_SYSROOT="$(xcrun --sdk iphoneos --show-sdk-path)" \
        -DCMAKE_OSX_ARCHITECTURES=arm64 -DCMAKE_OSX_DEPLOYMENT_TARGET=17.0 -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_C_COMPILER=/usr/bin/clang -DCMAKE_CXX_COMPILER=/usr/bin/clang++ \
        -DLLVM_TABLEGEN="$R/toolchains/llvm-host-build/bin/llvm-tblgen" -DCMAKE_MACOSX_BUNDLE=OFF \
        -DLLVM_BUILD_UTILS=Off -DLLVM_BUILD_TOOLS=Off -DLLVM_TARGETS_TO_BUILD= \
        -DLLVM_INCLUDE_TESTS=Off -DLLVM_INCLUDE_EXAMPLES=Off -DLLVM_INCLUDE_BENCHMARKS=Off \
        -DLLVM_INCLUDE_UTILS=Off -DLLVM_ENABLE_TERMINFO=Off -DLLVM_ENABLE_LIBXML2=Off \
        -DLLVM_ENABLE_ZSTD=Off -DLLVM_ENABLE_ZLIB=Off
    run_log llvm-ios-build cmake --build toolchains/llvm-ios-build -j"$N"
}

dxmt() {
    if ! xcrun -sdk macosx metal -v > /dev/null 2>&1; then
        xcodebuild -downloadComponent MetalToolchain
    fi
    mkdir -p build/dxmt-ios/shader-headers
    for s in air_msad air_samplepos air_tessellation; do
        xcrun -sdk macosx metal -o "build/dxmt-ios/shader-headers/$s.air" \
            -c "dxmt/src/airconv/shaders/$s.metal" -std=metal3.1 --target=air64-apple-macos14.0
        (cd build/dxmt-ios/shader-headers && xxd -i "$s.air" | sed "s/${s}_air/${s}/g" > "$s.h")
    done
    run_log dxmt bash build/dxmt-ios/build.sh
    xcrun -sdk iphoneos libtool -static -o app/Madeira/libdxmt_combined.a \
        build/dxmt-ios/obj/*.o toolchains/llvm-ios-build/lib/*.a
}

pairing() {
    rustup target add aarch64-apple-ios
    run_log pairing bash build/rppairing-ios/build.sh
}

runtime() {
    mingw
    run_log dock bash build/madeira-dock/build.sh
    # Microsoft DLLs are not part of this source distribution. Users supply
    # licensed, unmodified copies themselves; see tools/fetch-vcruntime.md.
    mkdir -p app/Madeira/x86_64-vcruntime
    if [ "${BUILD_WOW64:-false}" = true ]; then
        run_log wine-i386 bash build/wine-i386/build.sh
        run_log fex-wow64 bash build/fex-wow64/build.sh
    fi
}

archive() {
    bash build/stage-licenses.sh
    # Debug is the upstream-supported guest configuration. Release is unsafe
    # per docs/BUILDING.md; retain this intentionally for distributable IPAs.
    run_log xcodebuild xcodebuild -project app/Madeira.xcodeproj -scheme Madeira \
        -sdk iphoneos -destination 'generic/platform=iOS' -configuration Debug \
        CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY= \
        ENABLE_DEBUG_DYLIB=NO \
        DEVELOPMENT_TEAM= MADEIRA_BUNDLE_IDENTIFIER=com.ghb997.MadeiraZH \
        archive -archivePath "$R/build-out/Madeira.xcarchive"
    local app="$R/build-out/Madeira.xcarchive/Products/Applications/Madeira.app"
    test -f "$app/Madeira"
    xcrun dyld_info -exports "$app/Madeira" > "$LOG/exports.txt"
    for sym in macdrv_functions get_win_data release_win_data macdrv_view_create_metal_view \
               macdrv_view_get_metal_layer macdrv_view_release_metal_view; do
        grep -qE "_${sym}$" "$LOG/exports.txt" || { echo "Missing DXMT export $sym"; exit 1; }
    done
    mkdir -p build-out/Payload
    ditto "$app" build-out/Payload/Madeira.app
    # No developer identity is used. Preserve the requested entitlements in
    # an ad-hoc signature so sideloaders can read them before re-signing.
    find build-out/Payload -name embedded.mobileprovision -delete
    local payload="$R/build-out/Payload/Madeira.app"
    while IFS= read -r -d '' binary; do
        codesign --force --sign - --timestamp=none "$binary"
        codesign --verify --strict "$binary"
    done < <(find "$payload" -type f -name '*.dylib' -print0)
    while IFS= read -r -d '' bundle; do
        codesign --force --sign - --timestamp=none "$bundle"
        codesign --verify --strict "$bundle"
    done < <(find "$payload" -depth -type d \( -name '*.framework' -o -name '*.appex' \) -print0)
    codesign --force --sign - --timestamp=none --entitlements app/Madeira/Madeira.entitlements "$payload"
    codesign --verify --deep --strict --verbose=2 "$payload"
    codesign -d --entitlements :- "$payload" > build-out/requested-entitlements.plist 2> "$LOG/signature.txt"
    python3 - <<'PY'
from pathlib import Path
import plistlib
expected=plistlib.loads(Path('app/Madeira/Madeira.entitlements').read_bytes())
actual=plistlib.loads(Path('build-out/requested-entitlements.plist').read_bytes())
for key,value in expected.items():
    if actual.get(key) != value:
        raise SystemExit('Packaged entitlement does not match the source: '+key)
print('All source entitlements preserved for sideload re-signing')
PY
    local name="Madeira-ZH-0.1.3-${GITHUB_RUN_NUMBER:-local}-unsigned.ipa"
    (cd build-out && ditto -c -k --keepParent Payload "$name" && shasum -a 256 "$name" > "$name.sha256")
    python3 - <<'PY'
from pathlib import Path
import json, os, plistlib, subprocess
p=Path('build-out/Payload/Madeira.app/Info.plist')
info=plistlib.loads(p.read_bytes())
manifest={'source':subprocess.check_output(['git','rev-parse','HEAD'],text=True).strip(),
          'bundle_id':info['CFBundleIdentifier'],'version':info['CFBundleShortVersionString'],
          'xcode':subprocess.check_output(['xcodebuild','-version'],text=True).strip(),
          'wow64_built':os.environ.get('BUILD_WOW64')=='true',
          'signing':'ad-hoc placeholder with source entitlements; re-sign before installing'}
Path('build-out/build-manifest.json').write_text(json.dumps(manifest,ensure_ascii=False,indent=2)+'\n')
PY
}

case "${1:-}" in
    prepare|wine|fex|llvm|dxmt|pairing|runtime|archive) "$1" ;;
    all) prepare; wine; fex; llvm; dxmt; pairing; runtime; archive ;;
    *) echo 'Usage: bash tools/build-native-ci.sh prepare|wine|fex|llvm|dxmt|pairing|runtime|archive|all'; exit 2 ;;
esac
