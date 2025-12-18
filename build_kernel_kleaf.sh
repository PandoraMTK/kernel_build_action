#!/usr/bin/env bash

set -euo pipefail

# $1:KERNEL_NAME $2:VERSION $3:BUILD_TYPE $4:BUILD_NUMBER

# Kernel Name
KERNEL_NAME="$1"

# Kernel Version
KERNEL_VERSION="$2"

# Build Type
BUILD_TYPE="$3"

# Build Number
BUILD_NUMBER="$4"

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
ARCH="arm64"
DEFCONFIG="gki_defconfig"
MODULE_VER=""
MODULE_VERCODE=""

# Resources
TIME="$(date +"%H%M%S")"
WEEK="$(date +"%gw%V")"
DAY="$(printf "\x$(printf %x $((96 + $(date +"%u"))))")"

# Paths
KERNEL_DIR="$(pwd)/pandora"
OUT_ROOT="$(pwd)/out_pandora"
OUT_DIR="$OUT_ROOT/dist"
MOD_DIR="$OUT_DIR"
PKG_DIR="$OUT_ROOT/pkg"

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
    KERNEL_LOCALVER=$(grep_prop "CONFIG_LOCALVERSION" "$KERNEL_DIR/arch/$ARCH/configs/$DEFCONFIG" | tr -d '"')

    BRANCH="$(grep_prop "BRANCH" "$KERNEL_DIR/build.config.constants")"
    [ -z "$BRANCH" ] && BRANCH="$(grep_prop "BRANCH" "$KERNEL_DIR/build.config.common")"
    KMI_GENERATION="$(grep_prop "KMI_GENERATION" "$KERNEL_DIR/build.config.constants")"
    [ -z "$KMI_GENERATION" ] && KMI_GENERATION="$(grep_prop "KMI_GENERATION" "$KERNEL_DIR/build.config.common")"
    android_release=$(echo "$BRANCH" | sed -e '/android[0-9]\{2,\}/!{q255};s/^\(android[0-9]\{2,\}\)-.*/\1/')
    kernel_version="$(echo "$BRANCH" | awk -F- '{print $2}')"

    BETA_VERSION=""
    case "$BUILD_TYPE" in
    "REL")
        BETA_VERSION="$KERNEL_VERSION"
        MODULE_VER="$BETA_VERSION"
        MODULE_VERCODE="$(get_number "$MODULE_VER")"
        BUILD_NUMBER="n"
        ;;
    "BETA")
        BETA_VERSION="$WEEK$DAY"
        MODULE_VER="$BETA_VERSION"
        MODULE_VERCODE="$(date +"%g%m%d")"
        ;;
    *)
        BETA_VERSION="$KERNEL_VERSION-DEV"
        BUILD_NUMBER="n"
        MODULE_VERCODE="$(date +"%s")"
        MODULE_VER="$(date +"%y.%m.%d.$BETA_VERSION %H:%M:%S")"
        ;;
    esac

    [ -z "$BUILD_NUMBER" ] && BUILD_NUMBER="$(date +"%s")"
    [ "$BUILD_NUMBER" = "n" ] && BUILD_NUMBER=""
    # BUILD_NUMBER="$(echo "$BUILD_NUMBER" | cut -c1-8)"
    KMI_VER="$android_release-$KMI_GENERATION"
    # SCM_VERSION="g$(git rev-parse --verify HEAD | cut -c1-12)"
    # SCM_VERSION=""
    FULL_VERSION="$KERNEL_VER-$KMI_VER"
    # [ "$DEV" != "true" ] && FULL_VERSION="$FULL_VERSION-$SCM_VERSION"
    # [ -n "$BUILD_NUMBER" ] && FULL_VERSION="$FULL_VERSION-ab$BUILD_NUMBER"
    FULL_VERSION="$FULL_VERSION$KERNEL_LOCALVER-$KERNEL_NAME-$BETA_VERSION"
    export KERNELRELEASE="$FULL_VERSION"
    echo "$KERNELRELEASE" >"$KERNEL_DIR/.kernelrelease"
    echo "$time: $FULL_VERSION"
}
get_kernel_version

ZIMAGE_DIR="$OUT_DIR"
DATE_BEGIN=$(date +"%s")

echo
echo "-------------------"
echo "Making Kernel:"
echo "-------------------"
echo

tools/bazel run --extra_git_project pandora \
    --nokleaf_localversion \
    --config=fast --config=stamp \
    //pandora:kernel_aarch64_abi_dist -- \
    --destdir="$OUT_DIR"

DATE_END="$(date +"%s")"
DIFF="$((DATE_END - DATE_BEGIN))"
echo "-------------------"
echo "Build Completed, Time: $((DIFF / 60)) minute(s) and $((DIFF % 60)) seconds."
echo "-------------------"

rm -rf "$PKG_DIR"
mkdir -p "$PKG_DIR"
echo "-------------------"
echo "Making magisk module"
echo "-------------------"
MAGISK_PATH="$PKG_DIR/magisk"
rm -rf "$PKG_DIR/magisk"
cp -af "$KERNEL_DIR"/magisk "$MAGISK_PATH"
pushd "$MAGISK_PATH" >/dev/null 2>&1 || abort "No magisk module!"
sed -i "s#STATIC_VERSION#$MODULE_VER#g" module.prop
sed -i "s#STATIC_VERCODE#$MODULE_VERCODE#g" module.prop
echo "-------------------"
echo "Installing modules"
echo "-------------------"
MAGISK_MOD_PATH="$MAGISK_PATH/kernel_modules"
mkdir -p "$MAGISK_MOD_PATH"
for MOD in zsmalloc zram; do
    find "$MOD_DIR" -name "$MOD".ko -exec cp -af {} "$MAGISK_MOD_PATH/$MOD.ko" \;
done
echo "-------------------"
echo "Packing magisk module"
echo "-------------------"
# 7za a -mx1 -mmt"$THREADS" '-xr!config/old' '-xr!config/origin' magisk.zip ./* >/dev/null 2>&1
zip -q -b "$MAGISK_PATH" -1 -r "$PKG_DIR/magisk.zip" ./*
popd >/dev/null 2>&1 || abort "No root dir"

echo "-------------------"
echo "Making flash package"
echo "-------------------"
AK3_DIR=""$PKG_DIR/anykernel""
rm -rf "$AK3_DIR"
cp -af "$KERNEL_DIR"/anykernel "$AK3_DIR"
cp -af "$ZIMAGE_DIR"/Image.gz "$AK3_DIR"
mv -f "$PKG_DIR/magisk.zip" "$AK3_DIR"
pushd "$AK3_DIR" >/dev/null 2>&1 || abort "No anykernel!"
# 7za a -mx1 -mmt"$THREADS" anykernel.zip ./* >/dev/null 2>&1
zip -q -b "$AK3_DIR" -5 -r "$PKG_DIR/anykernel.zip" ./*
popd >/dev/null 2>&1 || abort "No root dir"

echo "-------------------"
echo "Outputing flash package"
echo "-------------------"
rm -f "$KERNEL_DIR"/*.zip
ZIPNAME="Kernel-$KERNEL_NAME-$kernel_version"
case "$BUILD_TYPE" in
"REL") ZIPNAME="$ZIPNAME-$BETA_VERSION" ;;
"BETA") ZIPNAME="$ZIPNAME-$BETA_VERSION-$TIME" ;;
*) ZIPNAME="$ZIPNAME-$WEEK$DAY-$TIME-$BETA_VERSION" ;;
esac

mv -f "$PKG_DIR/anykernel.zip" "$GITHUB_WORKSPACE/$ZIPNAME".zip

echo "-------------------"
echo "Output: $ZIPNAME.zip"
echo "-------------------"

echo "$ZIPNAME" >"$GITHUB_WORKSPACE/.output"
