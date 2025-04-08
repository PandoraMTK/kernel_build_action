#!/usr/bin/env bash

set -euo pipefail

# $1:CLANG_PATH $2:VERSION $3:DEVICE
# Compiler
CLANG_PATH="$1"

# Kernel Version
KERNEL_VERSION="$2"

# Build Type
DEVICE="$3"

abort() {
    echo "$1"

    exit 1
}

# Exports
KERNEL_NAME="BocchiTheKernel"
export PATH="$CLANG_PATH:$PATH"
export CCACHE="ccache"
export CC="$CLANG_PATH/clang"
export CXX="$CLANG_PATH/clang++"
export CLANG_TRIPLE="aarch64-linux-gnu"
export CROSS_COMPILE_COMPAT="arm-linux-gnueabihf-"
export CROSS_COMPILE="aarch64-linux-gnu-"
export ARCH="arm64"
export SUBARCH="$ARCH"
export KBUILD_BUILD_USER="Laulan56"
export KBUILD_BUILD_HOST="GHCI"
export DEFCONFIG="${DEVICE}_defconfig"
export BRANCH
export KMI_GENERATION
export LOCALVERSION

# Resources
THREADS="$(nproc --all)"

# Paths
KERNEL_DIR="$(pwd)"
OUT_DIR="$KERNEL_DIR/../build_dir"

LOCALVERSION="-$KERNEL_VERSION"

TIME="$(date +"%H%M%S")"
FULL_VERSION="BocchiTheKernel-$KERNEL_VERSION"
echo "$TIME: $FULL_VERSION"

ZIMAGE_DIR="$OUT_DIR/arch/arm64/boot"
DATE_BEGIN=$(date +"%s")

echo
echo "-------------------"
echo "Making Kernel:"
echo "-------------------"
echo
make CC="$CCACHE $CC" LLVM=1 LLVM_IAS=1 O="$OUT_DIR" ARCH=$ARCH "$DEFCONFIG" -j"$THREADS"
make CC="$CCACHE $CC" LLVM=1 LLVM_IAS=1 O="$OUT_DIR" ARCH=$ARCH -j"$THREADS" Image

DATE_END="$(date +"%s")"
DIFF="$((DATE_END - DATE_BEGIN))"
echo "-------------------"
echo "Build Completed, Time: $((DIFF / 60)) minute(s) and $((DIFF % 60)) seconds."
echo "-------------------"

ls -a "$ZIMAGE_DIR"

echo "-------------------"
echo "Making magisk module"
echo "-------------------"
cp -af "$KERNEL_DIR"/magisk "$OUT_DIR/"
cd "$OUT_DIR"/magisk || abort "No magisk module!"
sed -i "s#STATIC_VERSION#$MODULE_VER#g" module.prop
sed -i "s#STATIC_VERCODE#$MODULE_VERCODE#g" module.prop
# 7zz a -mx1 -mmt"$THREADS" magisk.zip ./* >/dev/null 2>&1
zip -b "$OUT_DIR"/magisk -5 -r magisk.zip ./* >/dev/null 2>&1

echo "-------------------"
echo "Making flash package"
echo "-------------------"
cp -af "$KERNEL_DIR"/anykernel "$OUT_DIR"
cp -af "$ZIMAGE_DIR"/Image "$OUT_DIR"/anykernel/
mv -f magisk.zip "$OUT_DIR"/anykernel/
cd "$OUT_DIR"/anykernel/ || abort "No anykernel!"
# 7zz a -mx1 -mmt"$THREADS" anykernel.zip ./* >/dev/null 2>&1
zip -b "$OUT_DIR"/anykernel -5 -r anykernel.zip ./* >/dev/null 2>&1

cd .. || abort "Dir missing!"
rm -f "$KERNEL_DIR"/*.zip
case "$DEVICE" in
"odin") DEVICE_NAME="MIX4" ;;
"haydn") DEVICE_NAME="K40P" ;;
"venus") DEVICE_NAME="MI11" ;;
"star") DEVICE_NAME="MI11PU" ;;
*) DEVICE_NAME="ERROR" ;;
esac
ZIPNAME="$KERNEL_NAME-$KERNEL_VERSION-$DEVICE_NAME"

mv -f "$OUT_DIR"/tmp/tmp.zip "$KERNEL_DIR/$ZIPNAME".zip
rm -rf "$OUT_DIR"/tmp
echo "-------------------"
echo "Output: $ZIPNAME.zip"
echo "-------------------"
echo "$ZIPNAME" >"$KERNEL_DIR/.output"
