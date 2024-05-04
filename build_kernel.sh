#!/usr/bin/env bash

set -euo pipefail

# $1:CLANG_PATH $2:KERNEL_NAME $3:VERSION $4:BUILD_TYPE
# $5:BUILD_NUMBER $6:KSU $7:FULL_LTO $8:NOBUILD
# Compiler
CLANG_PATH="$1"

# Kernel Name
KERNEL_NAME="$2"

# Kernel Version
KERNEL_VERSION="$3"

# Build Type
BUILD_TYPE="$4"

# Build Number
export BUILD_NUMBER="$5"

# Support KernelSU
KSU="$6"

# Use Full LTO
FULL_LTO="$7"

grep_prop() {
    local REGEX="s/^$1=//p"
    shift
    local FILES=$@
    cat $FILES 2>/dev/null | dos2unix | sed -n "$REGEX" | head -n 1

    return 0
}

abort() {
    echo "$1"

    exit 1
}

# Exports
export PATH="$CLANG_PATH:$PATH"
export CC="ccache $CLANG_PATH/clang"
export CXX="ccache $CLANG_PATH/clang++"
export CLANG_TRIPLE="aarch64-linux-gnu"
export CROSS_COMPILE_COMPAT="arm-linux-gnueabi-"
export CROSS_COMPILE="aarch64-linux-gnu-"
export ARCH="arm64"
export SUBARCH="$ARCH"
export KBUILD_BUILD_USER="GHCI"
export KBUILD_BUILD_HOST="Pandora"
export DEFCONFIG="gki_defconfig"
export BRANCH
export KMI_GENERATION
export LOCALVERSION

# Resources
THREADS="$(nproc --all)"

# Paths
KERNEL_DIR="$(pwd)"
INSTALL_MOD_PATH="$KERNEL_DIR/magisk/kernel_modules"
OUT_DIR="$KERNEL_DIR/.out"
MOD_DIR="$KERNEL_DIR/out"

# Kernel Branch and KMI Generation
BRANCH="$(grep_prop "BRANCH" "$KERNEL_DIR/build.config.constants")"
[ -z "$BRANCH" ] && BRANCH="$(grep_prop "BRANCH" "$KERNEL_DIR/build.config.common")"
KMI_GENERATION="$(grep_prop "KMI_GENERATION" "$KERNEL_DIR/build.config.common")"
android_release=$(echo "$BRANCH" | sed -e '/android[0-9]\{2,\}/!{q255};s/^\(android[0-9]\{2,\}\)-.*/\1/')
kernel_version="$(echo "$BRANCH" | awk -F- '{print $2}')"

TIME="$(date +"%H%M%S")"
WEEK="$(date +"%gw%V")"
DAY="$(printf "\x$(printf %x $((96 + $(date +"%u"))))")"

# Vars
BETA_VERSION=""

case "$BUILD_TYPE" in
"REL")
    BUILD_NUMBER="n"
    BETA_VERSION="$KERNEL_VERSION"
    ;;
"BETA")
    BUILD_NUMBER="n"
    BETA_VERSION="$WEEK$DAY"
    ;;
"DEBUG")
    BETA_VERSION="$WEEK$DAY"
    ;;
*)
    BUILD_NUMBER="n"
    BETA_VERSION="$DEV"
    ;;
esac
LOCALVERSION="-$KERNEL_NAME-$BETA_VERSION"

[ -z "$BUILD_NUMBER" ] && BUILD_NUMBER="$(date +"%s")"
[ "$BUILD_NUMBER" = "n" ] && BUILD_NUMBER=""
BUILD_NUMBER="$(echo "$BUILD_NUMBER" | cut -c1-8)"
SCM_VERSION="$android_release-$KMI_GENERATION-g$(git rev-parse --verify HEAD | cut -c1-12)"
FULL_VERSION="$KERNEL_NAME-$BETA_VERSION-$SCM_VERSION"
[ -z "$BUILD_NUMBER" ] && echo "$TIME: $FULL_VERSION" || echo "$TIME: $FULL_VERSION-ab$BUILD_NUMBER"

ZIMAGE_DIR="$OUT_DIR/arch/arm64/boot"
DATE_BEGIN=$(date +"%s")

echo
echo "-------------------"
echo "Making Kernel:"
echo "-------------------"
echo
rm -rf "$MOD_DIR"
make CC="$CC" LLVM=1 LLVM_IAS=1 O="$OUT_DIR" ARCH=$ARCH $DEFCONFIG -j"$THREADS"
make CC="$CC" LLVM=1 LLVM_IAS=1 O="$OUT_DIR" savedefconfig -j"$THREADS"
if $KSU; then
    echo "-------------------"
    echo "Enabling KSU"
    echo "-------------------"
    "$KERNEL_DIR/scripts/config" --file "$OUT_DIR/.config" -e KSU
fi
if $FULL_LTO; then
    echo "-------------------"
    echo "Enabling FullLTO"
    echo "-------------------"
    "$KERNEL_DIR/scripts/config" --file "$OUT_DIR/.config" -d LTO_CLANG_THIN
    "$KERNEL_DIR/scripts/config" --file "$OUT_DIR/.config" -e LTO_CLANG_FULL
else
    echo "-------------------"
    echo "Enabling ThinLTO"
    echo "-------------------"
    "$KERNEL_DIR/scripts/config" --file "$OUT_DIR/.config" -d LTO_CLANG_Full
    "$KERNEL_DIR/scripts/config" --file "$OUT_DIR/.config" -e LTO_CLANG_Thin
fi
make CC="$CC" LLVM=1 LLVM_IAS=1 O="$OUT_DIR" ARCH=$ARCH -j"$THREADS" Image modules Image.gz 2>&1
make CC="$CC" LLVM=1 LLVM_IAS=1 O="$OUT_DIR" modules_install INSTALL_MOD_PATH="$MOD_DIR" INSTALL_MOD_STRIP=1 ARCH=$ARCH -j"$THREADS"

DATE_END="$(date +"%s")"
DIFF="$((DATE_END - DATE_BEGIN))"
echo "-------------------"
echo "Build Completed, Time: $((DIFF / 60)) minute(s) and $((DIFF % 60)) seconds."
echo "-------------------"

ls -a "$ZIMAGE_DIR"

echo "-------------------"
echo "Installing modules"
echo "-------------------"
mkdir -p "$INSTALL_MOD_PATH"
cp -af "$MOD_DIR"/lib/modules/*/kernel/drivers/block/zram/zram.ko "$INSTALL_MOD_PATH"/zram.ko
cd "$KERNEL_DIR"/magisk || abort "No magisk module!"
7zz a -mx1 -mmt"$THREADS" '-xr!config/old' '-xr!config/origin' magisk.zip ./* >/dev/null 2>&1

echo "-------------------"
echo "Making magisk module"
echo "-------------------"
mkdir -p "$OUT_DIR"/tmp
cp -fp "$ZIMAGE_DIR"/Image.gz "$OUT_DIR"/tmp
cp -afrp "$KERNEL_DIR"/anykernel/* "$OUT_DIR"/tmp
mv -f "$KERNEL_DIR/magisk/magisk.zip" "$OUT_DIR"/tmp/

cd "$OUT_DIR"/tmp || abort "No anykernel!"

echo "-------------------"
echo "Making flash package"
echo "-------------------"
7zz a -mx1 -mmt"$THREADS" tmp.zip ./* >/dev/null 2>&1
cd .. || abort "Dir missing!"
rm -f "$KERNEL_DIR"/*.zip
ZIPNAME="Kernel-$KERNEL_NAME-$kernel_version"
case "$BUILD_TYPE" in
"REL") ZIPNAME="$ZIPNAME-$BETA_VERSION" ;;
*) ZIPNAME="$ZIPNAME-$BETA_VERSION-$TIME" ;;
esac
mv -f "$OUT_DIR"/tmp/tmp.zip "$KERNEL_DIR/$ZIPNAME".zip
rm -rf "$OUT_DIR"/tmp
echo "-------------------"
echo "Output: $ZIPNAME.zip"
echo "-------------------"
echo "$ZIPNAME" >"$KERNEL_DIR/.output"
