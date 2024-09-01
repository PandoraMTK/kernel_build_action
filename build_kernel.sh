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
BUILD_NUMBER="$5"

# Support KernelSU
# KSU="$6"

# Use Full LTO
FULL_LTO="$7"

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
export PATH="$CLANG_PATH:$PATH"
export CCACHE="ccache"
export CC="$CLANG_PATH/clang"
export CXX="$CLANG_PATH/clang++"
export CLANG_TRIPLE="aarch64-linux-gnu"
export CROSS_COMPILE_COMPAT="arm-linux-gnueabi-"
export CROSS_COMPILE="aarch64-linux-gnu-"
export ARCH="arm64"
export SUBARCH="$ARCH"
export KBUILD_BUILD_USER="GHCI"
export KBUILD_BUILD_HOST="Pandora"
export DEFCONFIG="gki_defconfig"
MODULE_VER=""
MODULE_VERCODE=""

# Resources
THREADS="$(($(nproc --all) - 1))"
TIME="$(date +"%H%M%S")"
WEEK="$(date +"%gw%V")"
DAY="$(printf "\x$(printf %x $((96 + $(date +"%u"))))")"

# Paths
KERNEL_DIR="$(pwd)"
INSTALL_MOD_PATH="$KERNEL_DIR/magisk/kernel_modules"
OUT_DIR="$KERNEL_DIR/../build_dir"
MOD_DIR="$KERNEL_DIR/../out_dir"

# Kernel Branch and KMI Generation
get_kernel_version() {
    local BRANCH
    local KMI_GENERATION
    local time

    time="$(date +"%H:%M:%S")"

    VERSION="$(grep_prop_space VERSION "$KERNEL_DIR/Makefile")"
    PATCHLEVEL="$(grep_prop_space PATCHLEVEL "$KERNEL_DIR/Makefile")"
    SUBLEVEL="$(grep_prop_space SUBLEVEL "$KERNEL_DIR/Makefile")"

    KERNEL_VER="$VERSION.$PATCHLEVEL.$SUBLEVEL"
    KERNEL_LOCALVER=$(grep_prop "CONFIG_LOCALVERSION" "$OUT_DIR/.config" | tr -d '"')

    BRANCH="$(grep_prop "BRANCH" "$KERNEL_DIR/build.config.constants")"
    [ -z "$BRANCH" ] && BRANCH="$(grep_prop "BRANCH" "$KERNEL_DIR/build.config.common")"
    KMI_GENERATION="$(grep_prop "KMI_GENERATION" "$KERNEL_DIR/build.config.common")"
    android_release=$(echo "$BRANCH" | sed -e '/android[0-9]\{2,\}/!{q255};s/^\(android[0-9]\{2,\}\)-.*/\1/')
    kernel_version="$(echo "$BRANCH" | awk -F- '{print $2}')"

    BETA_VERSION=""
    case "$BUILD_TYPE" in
    "REL")
        BETA_VERSION="$KERNEL_VERSION"
        BUILD_NUMBER="n"
        MODULE_VER="$BETA_VERSION"
        MODULE_VERCODE="$(get_number "$MODULE_VER")"
        ;;
    "BETA")
        BETA_VERSION="$WEEK$DAY"
        MODULE_VER="$BETA_VERSION"
        MODULE_VERCODE="$(date +"%g%m%d")"
        ;;
    *)
        BETA_VERSION="DEV"
        BUILD_NUMBER="n"
        MODULE_VERCODE="$(date +"%s")"
        MODULE_VER="$BETA_VERSION\_$(date +"%g%m%d%H%M%S")"
        ;;
    esac

    [ -z "$BUILD_NUMBER" ] && BUILD_NUMBER="$(date +"%s")"
    [ "$BUILD_NUMBER" = "n" ] && BUILD_NUMBER=""
    BUILD_NUMBER="$(echo "$BUILD_NUMBER" | cut -c1-8)"
    KMI_VER="$android_release-$KMI_GENERATION"
    SCM_VERSION="$KMI_VER-g$(git rev-parse --verify HEAD | cut -c1-12)"
    FULL_VERSION="$KERNEL_VER-$KERNEL_NAME-$BETA_VERSION-$SCM_VERSION"
    [ -n "$BUILD_NUMBER" ] && FULL_VERSION="$FULL_VERSION-ab$BUILD_NUMBER"
    FULL_VERSION="$FULL_VERSION$KERNEL_LOCALVER"
    export KERNELRELEASE="$FULL_VERSION"
    echo "$time: $FULL_VERSION"
}
get_kernel_version

ZIMAGE_DIR="$OUT_DIR/arch/arm64/boot"
DATE_BEGIN=$(date +"%s")

echo
echo "-------------------"
echo "Making Kernel:"
echo "-------------------"
echo
rm -rf "$MOD_DIR"
make CC="$CC" LLVM=1 LLVM_IAS=1 O="$OUT_DIR" ARCH=$ARCH KERNELRELEASE="$FULL_VERSION" $DEFCONFIG -j"$THREADS"
if $FULL_LTO; then
    echo "-------------------"
    echo "Enabling FullLTO"
    echo "-------------------"
    "$KERNEL_DIR/scripts/config" --file "$OUT_DIR/.config" -d LTO_NONE
    "$KERNEL_DIR/scripts/config" --file "$OUT_DIR/.config" -d LTO_CLANG_THIN
    "$KERNEL_DIR/scripts/config" --file "$OUT_DIR/.config" -e LTO_CLANG_FULL
else
    echo "-------------------"
    echo "Enabling ThinLTO"
    echo "-------------------"
    "$KERNEL_DIR/scripts/config" --file "$OUT_DIR/.config" -d LTO_NONE
    "$KERNEL_DIR/scripts/config" --file "$OUT_DIR/.config" -d LTO_CLANG_FULL
    "$KERNEL_DIR/scripts/config" --file "$OUT_DIR/.config" -e LTO_CLANG_Thin
fi
make CC="$CCACHE $CC" LLVM=1 LLVM_IAS=1 O="$OUT_DIR" ARCH=$ARCH KERNELRELEASE="$FULL_VERSION" -j"$THREADS" Image modules 2>&1
make CC="$CC" LLVM=1 LLVM_IAS=1 O="$OUT_DIR" ARCH=$ARCH KERNELRELEASE="$FULL_VERSION" INSTALL_MOD_PATH="$MOD_DIR" INSTALL_MOD_STRIP=1 -j"$THREADS" modules_install 2>&1

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
for MOD in zram perfmgr; do
    find "$MOD_DIR" -name "$MOD".ko -exec cp -af {} "$INSTALL_MOD_PATH" \;
done

echo "-------------------"
echo "Making magisk module"
echo "-------------------"
cp -af "$KERNEL_DIR"/magisk "$OUT_DIR/"
cd "$OUT_DIR"/magisk || abort "No magisk module!"
sed -i "s#STATIC_VERSION#$MODULE_VER#g" module.prop
sed -i "s#STATIC_VERCODE#$MODULE_VERCODE#g" module.prop
7zz a -mx1 -mmt"$THREADS" '-xr!config/old' '-xr!config/origin' magisk.zip ./* >/dev/null 2>&1

echo "-------------------"
echo "Making flash package"
echo "-------------------"
cp -af "$KERNEL_DIR"/anykernel "$OUT_DIR"
cp -af "$ZIMAGE_DIR"/Image "$OUT_DIR"/anykernel/
mv -f magisk.zip "$OUT_DIR"/anykernel/
cd "$OUT_DIR"/anykernel/ || abort "No anykernel!"
7zz a -mx1 -mmt"$THREADS" anykernel.zip ./* >/dev/null 2>&1

echo "-------------------"
echo "Outputting flash package"
echo "-------------------"
cd .. || abort "Dir missing!"
rm -f "$KERNEL_DIR"/*.zip
ZIPNAME="Kernel-$KERNEL_NAME-$kernel_version"
case "$BUILD_TYPE" in
"REL") ZIPNAME="$ZIPNAME-$BETA_VERSION" ;;
*) ZIPNAME="$ZIPNAME-$BETA_VERSION-$TIME" ;;
esac

mv -f "$OUT_DIR"/anykernel/anykernel.zip "$KERNEL_DIR/$ZIPNAME".zip

echo "-------------------"
echo "Output: $ZIPNAME.zip"
echo "-------------------"

echo "$ZIPNAME" >"$KERNEL_DIR/.output"
