#!/usr/bin/env bash

set -euo pipefail

# $1:CLANG_PATH $2:DEVICE $3:VERSION
# Compiler
CLANG_PATH="$1"

# Device
DEVICE="$2"

# Kernel Version
KERNEL_VERSION="$3"

grep_prop() {
    local REGEX="s/^$1=//p"
    shift
    local FILES=$@
    cat $FILES 2>/dev/null | dos2unix | sed -n "$REGEX" | head -n 1

    return 0
}

grep_prop_space() {
    local REGEX="s/^$1 = //p"
    shift
    local FILES=$@
    cat $FILES 2>/dev/null | dos2unix | sed -n "$REGEX" | head -n 1

    return 0
}

abort() {
    echo "$1"

    exit 1
}

get_number() {
    echo "$1" | awk -F "" '
{
  for(i=1;i<=NF;i++) 
  {  
    if ($i ~ /[[:digit:]]/)     
    {
      str=$i
      str1=(str1 str)
    }  
  } 
  print str1
}'
}

# Exports
KERNEL_NAME="MarisaKernel"
export PATH="$CLANG_PATH:$PATH"
export CCACHE="ccache"
export CC="$CLANG_PATH/clang"
export CXX="$CLANG_PATH/clang++"
export CROSS_COMPILE="aarch64-linux-gnu-"
export CROSS_COMPILE_COMPAT="arm-linux-gnueabihf-"
export ARCH="arm64"
export SUBARCH="$ARCH"
export KBUILD_BUILD_USER="Laulan56"
export KBUILD_BUILD_HOST="GHCI"
export DEFCONFIG="${DEVICE}_defconfig"
export LOCALVERSION="-$KERNEL_VERSION"
MODULE_VER=""
MODULE_VERCODE=""

# Resources
THREADS="$(nproc --all)"

# Paths
KERNEL_DIR="$(pwd)"
OUT_DIR="$KERNEL_DIR/../build_dir"
MOD_DIR="$KERNEL_DIR/../out_dir"

ZIMAGE_DIR="$OUT_DIR/arch/arm64/boot"
DATE_BEGIN=$(date +"%s")

TIME="$(date +"%H:%M:%S")"
FULL_VERSION="$KERNEL_NAME-$KERNEL_VERSION"
MODULE_VER="$KERNEL_VERSION"
MODULE_VERCODE="$(get_number "$MODULE_VER")"

echo "$TIME: $FULL_VERSION"

echo
echo "-------------------"
echo "Making Kernel:"
echo "-------------------"
echo
rm -rf "$MOD_DIR"
make CC="$CCACHE $CC" LLVM=1 LLVM_IAS=1 O="$OUT_DIR" ARCH=$ARCH "$DEFCONFIG" LOCALVERSION="$LOCALVERSION" -j"$THREADS"
echo "-------------------"
echo "Enabling ThinLTO"
echo "-------------------"
"$KERNEL_DIR/scripts/config" --file "$OUT_DIR/.config" -d LTO_NONE
"$KERNEL_DIR/scripts/config" --file "$OUT_DIR/.config" -d LTO_CLANG_FULL
"$KERNEL_DIR/scripts/config" --file "$OUT_DIR/.config" -e LTO_CLANG_Thin
make CC="$CCACHE $CC" LLVM=1 LLVM_IAS=1 O="$OUT_DIR" ARCH=$ARCH LOCALVERSION="$LOCALVERSION" -j"$THREADS" Image dtbs 2>&1

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
7zz a -mx1 -mmt"$THREADS" magisk.zip ./* >/dev/null 2>&1

echo "-------------------"
echo "Making flash package"
echo "-------------------"
cp -af "$KERNEL_DIR"/anykernel "$OUT_DIR"
cp -af "$ZIMAGE_DIR"/Image "$OUT_DIR"/anykernel/
cp -af "$ZIMAGE_DIR"/dts/vendor/qcom/ukee.dtb "$OUT_DIR"/anykernel/dtb
mv -f magisk.zip "$OUT_DIR"/anykernel/
cd "$OUT_DIR"/anykernel/ || abort "No anykernel!"
7zz a -mx1 -mmt"$THREADS" anykernel.zip ./* >/dev/null 2>&1

echo "-------------------"
echo "Outputting flash package"
echo "-------------------"
cd .. || abort "Dir missing!"
rm -f "$KERNEL_DIR"/*.zip
ZIPNAME="$KERNEL_NAME-$DEVICE-$KERNEL_VERSION"
mv -f "$OUT_DIR"/anykernel/anykernel.zip "$KERNEL_DIR/$ZIPNAME".zip

echo "-------------------"
echo "Output: $ZIPNAME.zip"
echo "-------------------"

echo "$ZIPNAME" >"$KERNEL_DIR/.output"
