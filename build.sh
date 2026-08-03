#!/bin/bash
# 用法: bash build.sh
# 1. 编译 defconfig + 内核
# 2. 仅在编译完全通过时打包 AnyKernel3
# 3. 沙箱安全:使用项目本地 AK3 staging 目录,避免对 ~/mytools/ 的写依赖
# 4. 双重校验:Image-dtb 的 SHA 在 cp 前后必须一致,且包内必须包含本次构建的镜像

set -o pipefail

mkdir -p out

BUILD_CROSS_COMPILE=~/mytools/android_prebuilts_gcc_linux-x86_aarch64_aarch64-linux-android-4.9/bin/aarch64-linux-android-

CLANG_PATH=~/mytools/clang-r383902b1/bin
CROSS_COMPILE_ARM32=~/mytools/arm-linux-androideabi-4.9/bin/arm-linux-androideabi-

CLANG_TRIPLE=aarch64-linux-gnu-

DEFCONFIG=18115-debug_defconfig     # 编译配置文件,arch/arm64/configs 目录下查找
# 注意:DEFCONFIG 可能含行尾注释,使用第一个 token 即可
DEFCONFIG_BASE=$(echo "$DEFCONFIG" | awk '{print $1}')

# AK3 源模板(只读,可能因沙箱限制无法写入)
AK3_SRC=~/mytools/AK3-8150
# AK3 staging(项目本地,可写,每次构建清理重建,杜绝 stale Image-dtb)
AK3_STAGING=$(pwd)/out/ak3-staging
KERNEL_SRC=$(pwd)
OUT_DIR=$(pwd)/out

# --- 编译并行度 ---
# 自动检测本机逻辑核心数 (16c32t 机器 nproc=32)
# 如需手动指定, 取消下行注释并填入值 (例如 THREADS=32)
THREADS=$(nproc)
# THREADS=32

export ARCH=arm64
export PATH=${CLANG_PATH}:${PATH}

echo "=========================================="
echo "Build config: ${DEFCONFIG}"
echo "Threads: ${THREADS}"
echo "Output:   ${OUT_DIR}"
echo "=========================================="

# --- 步骤 1: 生成 .config ---
make -j${THREADS} -C $(pwd) O=${OUT_DIR} \
    CROSS_COMPILE=$BUILD_CROSS_COMPILE \
    CLANG_TRIPLE=$CLANG_TRIPLE \
    CROSS_COMPILE_ARM32=$CROSS_COMPILE_ARM32 \
    CC=clang \
    $DEFCONFIG

# --- 步骤 2: 编译内核 ---
make -j${THREADS} -C $(pwd) O=${OUT_DIR} \
    CROSS_COMPILE=$BUILD_CROSS_COMPILE \
    CLANG_TRIPLE=$CLANG_TRIPLE \
    CROSS_COMPILE_ARM32=$CROSS_COMPILE_ARM32 \
    CC=clang \
    -Werror \
    2>&1 | tee build.txt

BUILD_RESULT=${PIPESTATUS[0]}

# --- 步骤 3: 仅在编译成功时打包 ---
if [ $BUILD_RESULT -ne 0 ]; then
    echo "=========================================="
    echo "BUILD FAILED (exit code: ${BUILD_RESULT})"
    echo "Skipping AK3 packaging."
    echo "Check build.txt for errors."
    echo "=========================================="
    exit $BUILD_RESULT
fi

if [ ! -f $OUT_DIR/arch/arm64/boot/Image-dtb ]; then
    echo "=========================================="
    echo "BUILD 'SUCCESS' but no Image-dtb found!"
    echo "Skipping AK3 packaging."
    echo "=========================================="
    exit 1
fi

echo "=========================================="
echo "BUILD SUCCESS"
echo "=========================================="

# --- AnyKernel3 打包 ---
if ! command -v zip >/dev/null 2>&1; then
    echo "Warning: 'zip' command not found, skip AK3 packaging" >&2
    exit 0
fi

if [ ! -d "$AK3_SRC" ]; then
    echo "Error: AK3 source directory not found: $AK3_SRC" >&2
    exit 1
fi

# 从 defconfig 文件名提取设备/配置名 (例: 18115-debug_defconfig -> 18115-debug)
DEFCONFIG_NAME="${DEFCONFIG_BASE%_defconfig}"

# 从 Makefile 动态获取内核版本 (VERSION.PATCHLEVEL.SUBLEVEL)
KVER=$(sed -n 's/^VERSION = //p; s/^PATCHLEVEL = //p; s/^SUBLEVEL = //p' Makefile | tr '\n' '.' | sed 's/\.$//')

# 从 defconfig 读取 CONFIG_LOCALVERSION (去除首尾引号)
LOCALVER=$(grep "^CONFIG_LOCALVERSION=" arch/arm64/configs/$DEFCONFIG_BASE | cut -d= -f2- | tr -d '"')
# 若 defconfig 未指定，则尝试从已生成的 .config 读取
if [ -z "$LOCALVER" ] && [ -f $OUT_DIR/.config ]; then
    LOCALVER=$(grep "^CONFIG_LOCALVERSION=" $OUT_DIR/.config | cut -d= -f2- | tr -d '"')
fi

# 拼接内核全版本 (例: 4.14.210-Tonzy-bsKSU-perf)
if [ -n "$LOCALVER" ]; then
    FULL_VER="${KVER}${LOCALVER}"
else
    FULL_VER="${KVER}"
fi

# 时间戳精确到分 (例: 20260802-0945)
TIMESTAMP=$(date +"%Y%m%d-%H%M")

# 包名 (例: 18115-debug-4.14.210-Tonzy-bsKSU-perf-20260802-0945.zip)
PKG_NAME="${DEFCONFIG_NAME}-${FULL_VER}-${TIMESTAMP}.zip"

# --- 沙箱安全 staging 流程 ---
# 1. 删除旧 staging 目录(确保绝无 stale Image-dtb)
rm -rf "$AK3_STAGING"
# 2. 从 AK3_SRC 复制模板(只读 cp,沙箱通常允许)
cp -r "$AK3_SRC" "$AK3_STAGING"
if [ $? -ne 0 ]; then
    echo "Error: failed to copy AK3 template to staging: $AK3_SRC -> $AK3_STAGING" >&2
    exit 1
fi
# 3. 拷贝 Image-dtb 到 staging(项目本地,沙箱肯定可写)
cp -f $OUT_DIR/arch/arm64/boot/Image-dtb $AK3_STAGING/Image-dtb
if [ $? -ne 0 ]; then
    echo "Error: failed to copy Image-dtb to staging" >&2
    exit 1
fi
# 4. 双重校验:本次构建的 Image-dtb 必须原样存在于 staging
SRC_SHA=$(sha256sum $OUT_DIR/arch/arm64/boot/Image-dtb | awk '{print $1}')
DST_SHA=$(sha256sum $AK3_STAGING/Image-dtb | awk '{print $1}')
if [ "$SRC_SHA" != "$DST_SHA" ]; then
    echo "FATAL: Image-dtb SHA mismatch after copy!" >&2
    echo "  source: $SRC_SHA" >&2
    echo "  dest:   $DST_SHA" >&2
    exit 1
fi
echo "Image-dtb SHA verified: $SRC_SHA"

# 5. 在 staging 目录内打包
pushd $AK3_STAGING >/dev/null
zip -r9 $KERNEL_SRC/$PKG_NAME ./* >/dev/null
ZIP_RESULT=$?
popd >/dev/null

if [ $ZIP_RESULT -ne 0 ]; then
    echo "Error: zip failed with exit code $ZIP_RESULT" >&2
    exit $ZIP_RESULT
fi

# 6. 再次校验:包内 Image-dtb 的 SHA 必须与本次构建一致
PACKED_SHA=$(unzip -p "$KERNEL_SRC/$PKG_NAME" Image-dtb 2>/dev/null | sha256sum | awk '{print $1}')
if [ "$PACKED_SHA" != "$SRC_SHA" ]; then
    echo "FATAL: Image-dtb in package does NOT match the just-built image!" >&2
    echo "  built:  $SRC_SHA" >&2
    echo "  packed: $PACKED_SHA" >&2
    exit 1
fi
echo "Package Image-dtb SHA verified: $PACKED_SHA"

# 7. 清理 staging(保留最后一份 AK3_SRC Image-dtb 备份供本地调试)
# 注释:如需保留 staging 排查,删除下行 rm
rm -rf "$AK3_STAGING"

echo "=========================================="
echo "AK3 package created: $PKG_NAME"
echo "Path: $KERNEL_SRC/$PKG_NAME"
echo "Image-dtb SHA: $SRC_SHA (verified 2x: post-copy + post-zip)"
echo "=========================================="
