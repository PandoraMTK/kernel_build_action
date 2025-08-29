#!/usr/bin/env bash

set -euo pipefail

# $1:CLANG_PATH $2:KERNEL_NAME $3:VERSION $4:BUILD_TYPE
# $5:BUILD_NUMBER $6:FULL_LTO
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

# Use Full LTO
FULL_LTO="$6"

# CCACHE Type(ccache, sccache)
CCACHE_TYPE="$7"

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
export PATH="$CLANG_PATH/bin:$PATH"
export RUSTC_WRAPPER="sccache"
export RUSTFLAGS="-C linker=$CLANG_PATH/bin/clang -C link-arg=-fuse-ld=lld"
export CCACHE="$CCACHE_TYPE"
export CC="$CLANG_PATH/bin/clang"
export CXX="$CLANG_PATH/bin/clang++"
export CROSS_COMPILE="aarch64-linux-gnu-"
export CROSS_COMPILE_COMPAT="arm-linux-gnueabihf-"
export ARCH="arm64"
export SUBARCH="$ARCH"
export KBUILD_BUILD_USER="GHCI"
export KBUILD_BUILD_HOST="Pandora"
export DEFCONFIG="gki_defconfig"
MODULE_VER=""
MODULE_VERCODE=""
NO_LTO="false"
DEV="false"

# Resources
THREADS="$(nproc --all)"
TIME="$(date +"%H%M%S")"
WEEK="$(date +"%gw%V")"
DAY="$(printf "\x$(printf %x $((96 + $(date +"%u"))))")"

# Paths
KERNEL_DIR="$(pwd)"
MAGISK_MOD_PATH="$KERNEL_DIR/magisk/kernel_modules"
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
        DEV="true"
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
    echo "$time: $FULL_VERSION"
}
get_kernel_version

init_rust() {
    RUST="$(grep_prop "CONFIG_RUST" "$KERNEL_DIR/arch/$ARCH/configs/$DEFCONFIG")"
    [ "$RUST" != "y" ] && return 0
    [ ! -f "$KERNEL_DIR/scripts/min-tool-version.sh" ] && return 0
    RUSTC_VER="$(grep_prop "RUSTC_VERSION" "$KERNEL_DIR/build.config.constants")"
    [ "$RUSTC_VER" = "" ] && return 0

    NO_LTO=true

    rustup override set "$RUSTC_VER"
    rustup component add rust-src
    [ -f "$CLANG_PATH/bin/bindgen" ] && return 0
    cargo install --force --root "$CLANG_PATH" bindgen-cli
}
init_rust

ZIMAGE_DIR="$OUT_DIR/arch/arm64/boot"
DATE_BEGIN=$(date +"%s")

echo
echo "-------------------"
echo "Making Kernel:"
echo "-------------------"
echo
rm -rf "$MOD_DIR"

EXTRA_FLAGS="LLVM_IAS=1"
FDO_FILE="$KERNEL_DIR/android/gki/aarch64/afdo/kernel.afdo"
FDO_FILE1="$KERNEL_DIR/gki/aarch64/afdo/kernel.afdo"
if [ -f "$FDO_FILE" ]; then
    EXTRA_FLAGS="CLANG_AUTOFDO_PROFILE=$FDO_FILE"
fi
if [ -f "$FDO_FILE1" ]; then
    EXTRA_FLAGS="CLANG_AUTOFDO_PROFILE=$FDO_FILE1"
fi

make CC="$CC" LLVM=1 LLVM_IAS=1 "$EXTRA_FLAGS" O="$OUT_DIR" ARCH=$ARCH KERNELRELEASE="$FULL_VERSION" $DEFCONFIG -j"$THREADS"
if [ -f "$FDO_FILE" ]; then
    echo "-------------------"
    echo "Enabling AutoFDO"
    echo "-------------------"
    "$KERNEL_DIR/scripts/config" --file "$OUT_DIR/.config" -e CONFIG_AUTOFDO_CLANG
fi
if $NO_LTO; then
    echo "-------------------"
    echo "Disabling LTO"
    echo "-------------------"
    "$KERNEL_DIR/scripts/config" --file "$OUT_DIR/.config" -e LTO_NONE
    "$KERNEL_DIR/scripts/config" --file "$OUT_DIR/.config" -d LTO_CLANG_THIN
    "$KERNEL_DIR/scripts/config" --file "$OUT_DIR/.config" -d LTO_CLANG_FULL
elif $FULL_LTO; then
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
make CC="$CCACHE $CC" LLVM=1 LLVM_IAS=1 "$EXTRA_FLAGS" O="$OUT_DIR" ARCH=$ARCH KERNELRELEASE="$FULL_VERSION" -j"$THREADS" Image.gz modules 2>&1
make CC="$CCACHE $CC" LLVM=1 LLVM_IAS=1 "$EXTRA_FLAGS" O="$OUT_DIR" ARCH=$ARCH KERNELRELEASE="$FULL_VERSION" INSTALL_MOD_PATH="$MOD_DIR" INSTALL_MOD_STRIP=1 -j"$THREADS" modules_install 2>&1

DATE_END="$(date +"%s")"
DIFF="$((DATE_END - DATE_BEGIN))"
echo "-------------------"
echo "Build Completed, Time: $((DIFF / 60)) minute(s) and $((DIFF % 60)) seconds."
echo "-------------------"

ls -a "$ZIMAGE_DIR"

echo "-------------------"
echo "Installing modules"
echo "-------------------"
mkdir -p "$MAGISK_MOD_PATH"
for MOD in zram perfmgr bwmon crypto_zstdn crypto_zstdp crypto_lz4p perfmgr; do
    find "$MOD_DIR" -name "$MOD".ko -exec cp -af {} "$MAGISK_MOD_PATH" \;
done

echo "-------------------"
echo "Making magisk module"
echo "-------------------"
cp -af "$KERNEL_DIR"/magisk "$OUT_DIR/"
cd "$OUT_DIR"/magisk || abort "No magisk module!"
sed -i "s#STATIC_VERSION#$MODULE_VER#g" module.prop
sed -i "s#STATIC_VERCODE#$MODULE_VERCODE#g" module.prop
# 7zz a -mx1 -mmt"$THREADS" '-xr!config/old' '-xr!config/origin' magisk.zip ./* >/dev/null 2>&1
zip -q -b "$OUT_DIR"/magisk -5 -r magisk.zip ./*

echo "-------------------"
echo "Making flash package"
echo "-------------------"
cp -af "$KERNEL_DIR"/anykernel "$OUT_DIR"
cp -af "$ZIMAGE_DIR"/Image.gz "$OUT_DIR"/anykernel/
mv -f magisk.zip "$OUT_DIR"/anykernel/
cd "$OUT_DIR"/anykernel/ || abort "No anykernel!"
# 7zz a -mx1 -mmt"$THREADS" anykernel.zip ./* >/dev/null 2>&1
zip -q -b "$OUT_DIR"/anykernel -5 -r anykernel.zip ./*

echo "-------------------"
echo "Outputting flash package"
echo "-------------------"
cd .. || abort "Dir missing!"
rm -f "$KERNEL_DIR"/*.zip
ZIPNAME="Kernel-$KERNEL_NAME-$kernel_version"
case "$BUILD_TYPE" in
"REL") ZIPNAME="$ZIPNAME-$BETA_VERSION" ;;
"BETA") ZIPNAME="$ZIPNAME-$BETA_VERSION-$TIME" ;;
*) ZIPNAME="$ZIPNAME-$WEEK$DAY-$TIME-$BETA_VERSION" ;;
esac

mv -f "$OUT_DIR"/anykernel/anykernel.zip "$KERNEL_DIR/$ZIPNAME".zip

echo "-------------------"
echo "Output: $ZIPNAME.zip"
echo "-------------------"

echo "$ZIPNAME" >"$KERNEL_DIR/.output"
