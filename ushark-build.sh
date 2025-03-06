#!/bin/bash
#
# This file is part of PCAPdroid.
#
# PCAPdroid is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# PCAPdroid is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with PCAPdroid.  If not, see <http://www.gnu.org/licenses/>.
#
# Copyright 2024-25 - Emanuele Faranda
#

set -e

MIN_SDK=21
NDK_VERSION="26.3.11579264"
TOP_DIR=`readlink -f .`

LIBICONV_VERSION="1.17"
LIBICONV_SHA256="8f74213b56238c85a50a5329f77e06198771e70dd9a739779f4c02f65d971313"
GLIB2_VERSION="2.80.2"
GLIB2_SHA256="b9cfb6f7a5bd5b31238fd5d56df226b2dda5ea37611475bf89f6a0f9400fe8bd"
LIBGPGERROR_VERSION="1.49"
LIBGPGERROR_SHA256="8b79d54639dbf4abc08b5406fb2f37e669a2dec091dd024fb87dd367131c63a9"
LIBGCRYPT_VERSION="1.10.3"
LIBGCRYPT_SHA256="8b0870897ac5ac67ded568dcfadf45969cfa8a6beb0fd60af2a9eadc2a3272aa"
NGHTTP2_VERSION="1.62.1"
NGHTTP2_SHA256="3966ec82fda7fc380506d372a260d8d9b6e946be4deaef1fecc1a74b4809ae3d"
WIRESHARK_TAG="v4.1.0rc0-ushark"
USHARK_TAG="pcapdroid-v1.8.0"

function usage {
  echo "Usage: `basename $0` [args]"
  echo "Supported ABIs: armeabi-v7a arm64-v8a x86 x86_64"
  echo
  echo "Args:"
  echo "  -a, --abi abi           only build for the specified ABI"
  echo "  -b, --build lib         only build the specified lib"
  echo "  -j, --jobs n            specify the number of jobs for the builds"
  echo "  -t, --type type         set the build type: debug/release"
  echo "  clean                   clean the project"
}

# download_and_verify name "url" "optional sha256"
function download_and_verify {
  local fname="${2##*/}"

  if [[ ! -f "modules/$fname" ]]; then
    echo "Downloading $fname ..."
    wget -q --show-progress "$2" -O "modules/$fname"
  fi

  if [[ ! -z "$3" ]]; then
    echo "$3 modules/$fname" | sha256sum --check

    if [[ $? -ne 0 ]]; then
      echo "Checksum verification failed" >&2
      exit 1
    fi
  else
    echo "[WARNING] Checksum verification skipped for modules/$fname"
    echo -n "SHA256: "
    sha256sum modules/$fname | awk '{ print $1 }'
  fi

  rm -rf "modules/$1"
  mkdir -p "modules/$1"
  tar -xf "modules/$fname" -C "modules/$1" --strip-components=1
}

# # download_and_verify name "url" "tag/branch"
function clone_and_checkout {
  if [[ ! -d "modules/$1/.git" ]]; then
    rm -rf "modules/$1"
    git clone "$2" "modules/$1"
  fi

  cd "modules/$1"
  git fetch
  git reset --hard "$3"
  cd "$TOP_DIR"
}

function pull_dependencies {
  mkdir -p modules
  download_and_verify libiconv "https://ftp.gnu.org/pub/gnu/libiconv/libiconv-$LIBICONV_VERSION.tar.gz" $LIBICONV_SHA256
  download_and_verify glib2 "https://download.gnome.org/sources/glib/${GLIB2_VERSION%.*}/glib-$GLIB2_VERSION.tar.xz" $GLIB2_SHA256
  download_and_verify libgpg-error "https://www.gnupg.org/ftp/gcrypt/libgpg-error/libgpg-error-$LIBGPGERROR_VERSION.tar.bz2" $LIBGPGERROR_SHA256
  download_and_verify libgcrypt "https://gnupg.org/ftp/gcrypt/libgcrypt/libgcrypt-$LIBGCRYPT_VERSION.tar.bz2" $LIBGCRYPT_SHA256
  download_and_verify nghttp2 "https://github.com/nghttp2/nghttp2/releases/download/v$NGHTTP2_VERSION/nghttp2-$NGHTTP2_VERSION.tar.bz2" $NGHTTP2_SHA256

  clone_and_checkout wireshark "https://github.com/emanuele-f/wireshark" $WIRESHARK_TAG
  clone_and_checkout ushark "https://github.com/emanuele-f/ushark" $USHARK_TAG
}

function restore_glib2_meson_build {
  sed -i "s|libiconv = declare_dependency(.*|libiconv = dependency('iconv')|g" "$GLIB2_SRC/meson.build" 2>/dev/null
}

TARGET_ABI=
TARGET_LIB=
DO_CLEAN=
BUILD_TYPE=release
JOBS=`nproc --ignore 1`

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help)
      usage
      exit 0
      ;;
    -a|--abi)
      TARGET_ABI="$2"
      shift
      shift
      ;;
    -b|--build)
      TARGET_LIB="$2"
      shift
      shift
      ;;
    -t|--type)
      BUILD_TYPE="$2"
      shift
      shift
      ;;
    -j|--jobs)
      JOBS="$2"
      shift
      shift
      ;;
    clean)
      DO_CLEAN=1
      shift
      ;;
    *)
      echo "Invalid argument: $1" >&2
      usage
      exit 1
      ;;
  esac
done

MAKE="make -j$MAKE_JOBS"

if [ ! -z $DO_CLEAN ]; then
  rm -rf modules dist build
  restore_glib2_meson_build
  exit 0
fi

if [ -z "$ANDROID_HOME" ]; then
  echo "The ANDROID_HOME environment variable is not set" >&2
  exit 1
fi

ANDROID_NDK_ROOT="$ANDROID_HOME/ndk/$NDK_VERSION"
ANDROID_CMAKE_TOOLCHAIN="$ANDROID_NDK_ROOT/build/cmake/android.toolchain.cmake"
ANDROID_TOOLCHAIN="$ANDROID_NDK_ROOT/toolchains/llvm/prebuilt/linux-x86_64"

if [ ! -d "$ANDROID_NDK_ROOT" ]; then
  echo "The Android NDK root folder is missing: $ANDROID_NDK_ROOT" >&2
  exit 1
fi

if [ ! -f "$ANDROID_CMAKE_TOOLCHAIN" ]; then
  echo "The Android NDK cross compilation toolchain is missing: $ANDROID_CMAKE_TOOLCHAIN" >&2
  exit 1
fi

export PATH="$ANDROID_TOOLCHAIN/bin:$PATH"

pull_dependencies

ICONV_SRC="$TOP_DIR/modules/libiconv"
GLIB2_SRC="$TOP_DIR/modules/glib2"
GPGERROR_SRC="$TOP_DIR/modules/libgpg-error"
GCRYPT_SRC="$TOP_DIR/modules/libgcrypt"
NGHTTP2_SRC="$TOP_DIR/modules/nghttp2"
WIRESHARK_SRC="$TOP_DIR/modules/wireshark"
USHARK_SRC="$TOP_DIR/modules/ushark"

if [ -z "$TARGET_ABI" ]; then
  rm -rf dist build
fi
mkdir -p dist build

MESON_BUILD_TYPE=
BUILD_TYPE_CFLAGS=
if [[ "$BUILD_TYPE" == release ]]; then
  MESON_BUILD_TYPE=release
  BUILD_TYPE=Release
  BUILD_TYPE_CFLAGS="-O2"
elif [[ "$BUILD_TYPE" == debug ]]; then
  MESON_BUILD_TYPE=debug
  BUILD_TYPE=Debug
  BUILD_TYPE_CFLAGS="-g -O0"
else
  echo "Bad build type: $BUILD_TYPE" >&2
  usage
  exit 1
fi

ABI=
HOST=
CPU=
BUILD=
BUILD_ROOT=
INSTALL_DIR=
CUR_BUILD=
GPGERR_LOCKOBJ=
GPGERR_LOCKOBJ_DEST=

function select_abi {
  ABI="$1"
  local ABI_CFLAGS=
  local ABI_LDFLAGS=
  local TOOLS_PREFIX=

  case "$ABI" in
    armeabi-v7a)
      HOST=arm-linux-androideabi
      CPU=arm
      GPGERR_LOCKOBJ=lock-obj-pub.arm-unknown-linux-androideabi.h
      GPGERR_LOCKOBJ_DEST=$GPGERR_LOCKOBJ
      TOOLS_PREFIX="armv7a-linux-androideabi"
      ABI_CFLAGS="-march=armv7-a -mfloat-abi=softfp -mfpu=vfpv3-d16 -mthumb"
      ABI_LDFLAGS="-march=armv7-a -Wl,--fix-cortex-a8"
      ;;
    arm64-v8a)
      HOST=aarch64-linux-android
      CPU=aarch64
      GPGERR_LOCKOBJ=lock-obj-pub.aarch64-unknown-linux-android.h
      GPGERR_LOCKOBJ_DEST=$GPGERR_LOCKOBJ
      TOOLS_PREFIX="aarch64-linux-android"
      ;;
    x86)
      HOST=i686-linux-android
      CPU=x86
      GPGERR_LOCKOBJ=lock-obj-pub.i686-linux-android.h
      GPGERR_LOCKOBJ_DEST=lock-obj-pub.linux-android.h
      TOOLS_PREFIX="i686-linux-android"
      ;;
    x86_64)
      HOST=x86_64-linux-android
      CPU=x86_64
      GPGERR_LOCKOBJ=lock-obj-pub.linux-android.h
      GPGERR_LOCKOBJ_DEST=$GPGERR_LOCKOBJ
      TOOLS_PREFIX="x86_64-linux-android"
      ;;
    *)
      echo "Invalid ABI: $ABI" >&2
      exit 1
      ;;
  esac

  TOOLS_PREFIX="${TOOLS_PREFIX}${MIN_SDK}"
  BUILD_ROOT=`readlink -f ${TOP_DIR}/build/$ABI`
  INSTALL_DIR="$BUILD_ROOT/install"

  export CC="${TOOLS_PREFIX}-clang"
  export RANLIB="llvm-ranlib"
  export AR="llvm-ar"
  export NM="llvm-nm"
  export STRIP="llvm-strip"
  export OBJCOPY="llvm-objcopy"
  export READELF="llvm-readelf"

  local gc_sections_flags=
  if [[ $BUILD_TYPE == "Release" ]]; then
    # -f* together with gc-sections and exclude-libs removes unused functions
    gc_sections_flags="-fvisibility=hidden -ffunction-sections -fdata-sections"
  fi

  export CFLAGS="${BUILD_TYPE_CFLAGS} -fPIC ${gc_sections_flags} $ABI_CFLAGS"
  export LDFLAGS="${ABI_LDFLAGS}"
}

function build_iconv {
  # required by glib2 on older Android SDKs
  "${ICONV_SRC}/configure" --prefix="$INSTALL_DIR" \
      --host $HOST \
      --enable-static --disable-shared --disable-tests -disable-doc
  $MAKE install
}

function build_glib2 {
  # https://docs.gtk.org/glib/cross-compiling.html
  # https://mesonbuild.com/Cross-compilation.html
  cd "$GLIB2_SRC"

  # generate cross-file
  cross_file=`readlink -f ${BUILD}/cross-file.txt`
  cat > "$cross_file" <<EOF
[host_machine]
system = 'android'
cpu_family = '${CPU}'
cpu = '${CPU}'
endian = 'little'

[binaries]
c = '${CC}'
ar = '${AR}'
ld = '${CC}'
objcopy = '${OBJCOPY}'
strip = '${STRIP}'
EOF

  # patch to search iconv into the INSTALL_DIR
  restore_glib2_meson_build
  sed -i "s|libiconv = dependency('iconv')|libiconv = declare_dependency(\
    link_args : ['-L${INSTALL_DIR}/lib', '-liconv'],\
    include_directories : include_directories('${INSTALL_DIR}/include'))|g" "$GLIB2_SRC/meson.build"

  meson setup --cross-file "$cross_file" \
      --prefix="$INSTALL_DIR" \
      -Dselinux=disabled -Dxattr=false -Dlibmount=disabled \
      -Dbsymbolic_functions=false -Dtests=false -Dnls=disabled \
      -Dglib_debug=disabled -Dglib_assert=false -Dglib_checks=false \
      -Dlibelf=disabled -Dintrospection=disabled \
      -Ddefault_library=static \
      --buildtype=$MESON_BUILD_TYPE \
      "$BUILD"

  meson compile -C "$BUILD" glib-2.0
  cd "$BUILD"
  meson install

  restore_glib2_meson_build
}

function build_gpgerror {
  # https://stackoverflow.com/questions/45837496/compiling-libgcrypt-and-libgpgerror-for-android-with-cmake
  cd "$GPGERROR_SRC"
  ./autogen.sh
  cd "$BUILD"

  "$GPGERROR_SRC/configure" --prefix="$INSTALL_DIR" \
      --host $HOST \
      --enable-static --disable-shared --disable-tests -disable-doc

  # needed to manually generate lock-obj-pub. files. Run from /data/local/tmp
  cd src
  $MAKE gen-posix-lock-obj
  cd -

  # patch: install missing lock files
  lock_obj="$GPGERROR_SRC/src/syscfg/$GPGERR_LOCKOBJ_DEST"
  if [ ! -f "$lock_obj" ]; then
    cp ${TOP_DIR}/gpgerror-lock-obj/$GPGERR_LOCKOBJ "$lock_obj"
  fi

  # build and install
  $MAKE install
}

function build_gcrypt {
  cd "$GCRYPT_SRC"
  ./autogen.sh
  cd "$BUILD"

  # patch: remove tests generation, which fails in basic.c for x86_64
  sed -i "s/ tests$//g" "$GCRYPT_SRC/Makefile.in"

  "$GCRYPT_SRC/configure" --prefix="$INSTALL_DIR" \
      --host $HOST \
      --enable-static --disable-shared -disable-doc \
      --enable-ciphers="arcfour des aes rfc2268 seed camellia idea chacha20 sm4" \
      --enable-digests="md5 sha1 sha256 sha512 sha3 sm3 blake2" \
      --enable-pubkey-ciphers="dsa rsa ecc"

  # patch: disable MPI sub1/add1, which fails with "relocation R_386_32 cannot be used against local symbol" for x86
  if [[ $ABI == x86 ]]; then
    # mpih-sub1
    sed -i 's/^mpih_sub1 = mpih-sub1-asm.S$/mpih_sub1 = mpih-sub1.c/g' "mpi/Makefile"
    sed -i 's|mpih-sub1-asm.lo|mpih-sub1.lo|g' "mpi/Makefile"
    cp "$GCRYPT_SRC/mpi/generic/mpih-sub1.c" mpi/

    # mpih-add1-asm.o
    sed -i 's/^mpih_add1 = mpih-add1-asm.S$/mpih_add1 = mpih-add1.c/g' "mpi/Makefile"
    sed -i 's|mpih-add1-asm.lo|mpih-add1.lo|g' "mpi/Makefile"
    cp "$GCRYPT_SRC/mpi/generic/mpih-add1.c" mpi/
  fi

  $MAKE install
}

function build_nghttp2 {
  cd "$BUILD"

  "$NGHTTP2_SRC/configure" --prefix="$INSTALL_DIR" \
      --host $HOST \
      --enable-static --disable-shared \
      --enable-lib-only

  $MAKE install
}

function build_lemon {
  # build lemon for the build machine
  local host_wireshark="${HOST_BUILD}/wireshark"

  if [ ! -x "$host_wireshark/run/lemon" ]; then
    echo "[+] Build lemon..."

    rm -rf "$host_wireshark"
    mkdir -p "$host_wireshark"
    cd "$host_wireshark"

    cmake -DCMAKE_BUILD_TYPE=Release -DENABLE_STATIC=ON "$WIRESHARK_SRC"
    $MAKE lemon
  fi
}

function build_wireshark {
  # https://zwyuan.github.io/2016/07/18/cross-compile-wireshark-for-android
  cmake -DCMAKE_SYSTEM_NAME=Android -DCMAKE_TOOLCHAIN_FILE="$ANDROID_CMAKE_TOOLCHAIN"\
    -DANDROID_NDK="$ANDROID_NDK_ROOT" -DANDROID_ABI="$ABI" -DCMAKE_ANDROID_ARCH_ABI="$ABI" \
    -DCMAKE_SYSTEM_NAME=Android -DANDROID_PLATFORM="android-$MIN_SDK" -DCMAKE_SYSTEM_VERSION=$MIN_SDK \
    -DLEMON_BIN="${HOST_BUILD}/wireshark/run/lemon" \
    -DHAVE_C99_VSNPRINTF=TRUE \
    -DCMAKE_BUILD_TYPE=$BUILD_TYPE -DENABLE_STATIC=ON -DENABLE_WERROR=OFF \
    -DBUILD_tshark=ON \
    -DGLIB2_LIBRARY="$INSTALL_DIR/lib/libglib-2.0.a" \
    -DGLIB2_MAIN_INCLUDE_DIR="$INSTALL_DIR/include/glib-2.0" -DGLIB2_INTERNAL_INCLUDE_DIR="$INSTALL_DIR/lib/glib-2.0/include" \
    -DGTHREAD2_LIBRARY="$INSTALL_DIR/lib/libgthread-2.0.a" -DGTHREAD2_INCLUDE_DIR="$INSTALL_DIR/include" \
    -DGCRYPT_LIBRARY="$INSTALL_DIR/lib/libgcrypt.a" -DGCRYPT_INCLUDE_DIR="$INSTALL_DIR/include" \
    -DGCRYPT_ERROR_LIBRARY="$INSTALL_DIR/lib/libgpg-error.a" \
    -DPCRE2_LIBRARY="$INSTALL_DIR/lib/libpcre2-8.a" -DPCRE2_INCLUDE_DIR="$INSTALL_DIR/include" \
    -DNGHTTP2_LIBRARY="$INSTALL_DIR/lib/libnghttp2.a" -DNGHTTP2_INCLUDE_DIR="$INSTALL_DIR/include/nghttp2" \
    "$WIRESHARK_SRC"

  $MAKE epan wiretap version_info wsutil ui

  # install
  find ./run -maxdepth 1 -name '*.a' -exec cp "{}" "$INSTALL_DIR/lib" \;
}

function build_ushark {
  local src="`readlink -f \"$USHARK_SRC/libushark\"`"
  local wireshark_build="`readlink -f \"$BUILD/../wireshark\"`"
  local libs="${INSTALL_DIR}/lib"

  USHARK_CFLAGS="${CFLAGS} -I${WIRESHARK_SRC} -I${WIRESHARK_SRC}/include -I${wireshark_build}\
    -I${INSTALL_DIR}/include -I${INSTALL_DIR}/include/glib-2.0 -I${INSTALL_DIR}/lib/glib-2.0/include"

  echo "Building frame_tvbuff.o ..."
  ${CC} $USHARK_CFLAGS -c "$WIRESHARK_SRC/frame_tvbuff.c" -o frame_tvbuff.o

  echo "Building http2.o ..."
  ${CC} $USHARK_CFLAGS -c "$src/http2.c" -o http2.o

  echo "Building ushark.o ..."
  ${CC} $USHARK_CFLAGS -c "$src/ushark.c" -o ushark.o

  local gc_sections_flags=
  if [[ $BUILD_TYPE == "Release" ]]; then
    gc_sections_flags="-Wl,--gc-sections -Wl,--exclude-libs=ALL"
  fi

  echo "Building libushark.so ..."
  ${CC} $USHARK_CFLAGS $LDFLAGS $gc_sections_flags -z defs \
    -shared -Wl,-soname,libushark.so \
    -o libushark.so frame_tvbuff.o http2.o ushark.o \
    $libs/libwireshark.a \
		$libs/libwiretap.a $libs/libversion_info.a $libs/libwsutil.a \
		$libs/libui.a \
    $libs/libglib-2.0.a $libs/libgcrypt.a $libs/libgpg-error.a \
    $libs/libiconv.a $libs/libpcre2-8.a $libs/libnghttp2.a \
    $libs/libintl.a -lm

  dist="${TOP_DIR}/dist/jniLibs/$ABI"
  rm -rf "$dist"
  mkdir -p "$dist"
  cp libushark.so "$dist"

  if [[ $BUILD_TYPE == "Release" ]]; then
    ${STRIP} "$dist/libushark.so"
  fi

  ${READELF} --dynamic "$dist/libushark.so" | grep NEEDED

  # NOTE: Android won't load the library if it has .text relocations
  # https://android.googlesource.com/platform/bionic/+/master/android-changes-for-ndk-developers.md#Text-Relocations-Enforced-for-API-level-23
  if ${READELF} --dynamic "$dist/libushark.so" | grep TEXTREL; then
    echo ".text relocation found, this is a bug" >&2
    exit 1
  fi
}

function check_error {
  if [ ! -z $CUR_BUILD ]; then
    echo "Fatal error while building '$CUR_BUILD'" >&2
  fi
}

HOST_BUILD="${TOP_DIR}/build/host"
mkdir -p "${HOST_BUILD}"

compiled=
declare -a abis=(armeabi-v7a arm64-v8a x86 x86_64)
declare -a libs=(iconv glib2 gpgerror gcrypt nghttp2 wireshark ushark)

trap check_error EXIT

CUR_BUILD=lemon
build_lemon
CUR_BUILD=

for abi in "${abis[@]}"; do
  if [[ -z "$TARGET_ABI" ]] || [[ "$TARGET_ABI" == $abi ]]; then
    select_abi $abi
    compiled=1
    echo "## Target ABI: $abi"

    if [[ -z "$TARGET_LIB" ]]; then
      rm -rf "$BUILD_ROOT"
      rm -rf "$INSTALL_DIR"
    fi
    mkdir -p "$BUILD_ROOT"
    mkdir -p "$INSTALL_DIR"

    for lib in "${libs[@]}"; do
      if [[ -z "$TARGET_LIB" ]] || [[ "$TARGET_LIB" == $lib ]]; then
        BUILD="$BUILD_ROOT/$lib"
        rm -rf "$BUILD"
        mkdir -p "$BUILD"
        cd "$BUILD"

        echo "[+] Build $lib..."

        CUR_BUILD=$lib
        eval "build_$lib"
        CUR_BUILD=
      fi

      cd "$TOP_DIR"
    done
  fi
done

if [[ ! -z "$TARGET_ABI" ]] && [[ -z $compiled ]]; then
  echo "Invalid ABI: $TARGET_ABI" >&2
  usage
  exit 1
fi
