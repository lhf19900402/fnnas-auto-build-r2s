#!/usr/bin/env bash
set -euo pipefail

# Decompress and Patch Image
# 支持两种模式：GitHub Actions（云端）与本地 Linux
# - 云端：使用环境变量 SOURCE_FILE, VERSION（若未提供则尝试从仓库下载），输出压缩包并在 GITHUB_ENV 写入 FINAL_PKG_NAME
# - 本地：默认使用脚本同目录下的 .img.xz 文件，生产 rootfs.img、两个内核文件、README.md 并把它们放到一个文件夹内，且不做压缩或上传

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKDIR="$PWD"

is_github=false
if [ -n "${GITHUB_ACTIONS:-}" ]; then
  is_github=true
fi

echo "模式：$( [ "$is_github" = true ] && echo '云端 (GitHub Actions)' || echo '本地' )"

# find xz file
if [ "$is_github" = true ]; then
  XZ_FILE="${SOURCE_FILE:-}"
  if [ -z "$XZ_FILE" ]; then
    # fallback: try to find any .img.xz in workspace
    XZ_FILE=$(ls -1 $WORKDIR/*.img.xz 2>/dev/null | head -n1 || true)
  fi
else
  XZ_FILE=$(ls -1 "$DIR"/*.img.xz 2>/dev/null | sort -V | tail -n1 || true)
fi

if [ -z "$XZ_FILE" ] || [ ! -f "$XZ_FILE" ]; then
  echo "错误：未找到 .img.xz 文件（查看：$XZ_FILE）"
  exit 1
fi

echo "使用的 XZ 文件：$XZ_FILE"

# derive VERSION
if [ -n "${VERSION:-}" ]; then
  VER="$VERSION"
else
  BASENAME=$(basename "$XZ_FILE")
  VER=$(echo "$BASENAME" | grep -oE '_[0-9]+' | tr -d '_' | tail -n1 || true)
  if [ -z "$VER" ]; then
    VER="local-$(date +%s)"
  fi
fi

# 公共 README 模板写入函数（避免重复）
write_readme() {
  TARGET="$1"
  # 使用占位符写入模板，避免 heredoc 扩展或命令执行问题
  cat > "$TARGET" <<'EOF'
# fNOS UTM 虚拟机使用说明 (v__VER__)

## 🚀 UTM 配置关键点
1. **驱动器**: 导入 `rootfs.img`，接口选择 **VirtIO**。
2. **高级**:
  - 勾选 **"使用本地内核/initrd"**。
  - **External Kernel**: 选择 __RAW_KERNEL__。
  - **Initrd**: 选择 __RAW_INITRD__。
3. **启动参数 (Arguments)**:
```text
-append
"root=/dev/vda rw console=tty0 console=ttyAMA0 earlycon"
```

EOF

  # 替换占位符为实际变量值，先对替换字符串做转义
  sed_escape() { printf '%s' "$1" | sed -e 's/[\/&]/\\&/g'; }
  esc_ver=$(sed_escape "$VER")
  esc_kernel=$(sed_escape "$RAW_KERNEL")
  esc_initrd=$(sed_escape "$RAW_INITRD")

  sed -i "s/__VER__/$esc_ver/g; s/__RAW_KERNEL__/$esc_kernel/g; s/__RAW_INITRD__/$esc_initrd/g" "$TARGET"
}

WORK_TMP="$WORKDIR/fn_utm_work"
mkdir -p "$WORK_TMP"
cd "$WORK_TMP"

echo "正在解压 xz 到 source.img"
unxz -v -c "$XZ_FILE" > source.img

trap 'echo 正在清理; sync; sudo umount mnt_p1 2>/dev/null || true; sudo umount mnt_new 2>/dev/null || true; sudo losetup -d ${LOOP_DEV:-} 2>/dev/null || true; rm -f source.img' EXIT

sudo losetup -Pf --show source.img
LOOP_DEV=$(losetup -j source.img | cut -d: -f1 | head -n1)
if [ -z "$LOOP_DEV" ]; then
  echo "错误：设置 loop 设备失败"
  exit 2
fi

mkdir -p mnt_p1 mnt_new

echo "挂载 p1 以检测内核/initrd"
sudo mount -o ro "${LOOP_DEV}p1" mnt_p1

KERNEL_PATH=$(sudo find mnt_p1 -type f -name 'vmlinuz-*' ! -name '*.old' | sort -V | tail -n1 || true)
INITRD_PATH=$(sudo find mnt_p1 -type f -name 'initrd.img-*' ! -name '*.old' | sort -V | tail -n1 || true)

if [ -z "$KERNEL_PATH" ] || [ -z "$INITRD_PATH" ]; then
  echo "错误：在 p1 上未找到内核或 initrd"
  sudo umount mnt_p1 || true
  exit 3
fi

RAW_KERNEL=$(basename "$KERNEL_PATH")
RAW_INITRD=$(basename "$INITRD_PATH")

echo "复制内核文件：$RAW_KERNEL , $RAW_INITRD"
sudo cp "$KERNEL_PATH" "$WORKDIR/$RAW_KERNEL"
sudo cp "$INITRD_PATH" "$WORKDIR/$RAW_INITRD"
sudo umount mnt_p1

echo "克隆 p2 到 rootfs.img"
sudo dd if="${LOOP_DEV}p2" of=rootfs.img bs=1M status=none

echo "挂载 rootfs.img 以应用修复"
sudo mount rootfs.img mnt_new

echo "修改 fstab：禁用 /boot 挂载并使用 vda 作为根目录"
if [ -f mnt_new/etc/fstab ]; then
  sudo sed -i 's/^.*\/boot/#&/' mnt_new/etc/fstab || true
fi

echo "移除可能冲突的服务"
sudo rm -f mnt_new/etc/systemd/system/multi-user.target.wants/trim_miniscreen.service 2>/dev/null || true
sudo rm -f mnt_new/etc/systemd/system/multi-user.target.wants/trim_wayland.service 2>/dev/null || true

sync
sudo umount mnt_new

# At this point, rootfs.img exists in WORK_TMP

if [ "$is_github" = true ]; then
  PKG_DIR="fn_utm_${VER}"
  mkdir -p "$PKG_DIR"

  mv rootfs.img "$PKG_DIR/"
  mv "$WORKDIR/$RAW_KERNEL" "$PKG_DIR/"
  mv "$WORKDIR/$RAW_INITRD" "$PKG_DIR/"

  # create README in PKG_DIR (use shared template)
  write_readme "$PKG_DIR/README.md"

  echo "正在打包并压缩 ${PKG_DIR}.tar.xz"
  tar -cvf - "$PKG_DIR" | xz -z -T0 -v > "${PKG_DIR}.tar.xz"

  # expose final package name for GitHub Actions
  if [ -n "${GITHUB_ENV:-}" ]; then
    echo "FINAL_PKG_NAME=${PKG_DIR}.tar.xz" >> "$GITHUB_ENV"
    echo "RAW_KERNEL=$RAW_KERNEL" >> "$GITHUB_ENV"
    echo "RAW_INITRD=$RAW_INITRD" >> "$GITHUB_ENV"
    echo "VERSION=$VER" >> "$GITHUB_ENV"
  fi

  # move package to workspace root
  mv "${PKG_DIR}.tar.xz" "$WORKDIR/"

  echo "完成。包：${PKG_DIR}.tar.xz"
else
  # 本地模式：直接在脚本目录下创建输出文件夹，并将生成的文件移动进去
  OUT_DIR="$DIR/fn_utm_${VER}"
  mkdir -p "$OUT_DIR"

  mv rootfs.img "$OUT_DIR/"
  mv "$WORKDIR/$RAW_KERNEL" "$OUT_DIR/" 2>/dev/null || cp "$WORKDIR/$RAW_KERNEL" "$OUT_DIR/"
  mv "$WORKDIR/$RAW_INITRD" "$OUT_DIR/" 2>/dev/null || cp "$WORKDIR/$RAW_INITRD" "$OUT_DIR/"

  # 使用共享模板写入 README，然后追加本地文件列表
  write_readme "$OUT_DIR/README.md"
  cat >> "$OUT_DIR/README.md" <<EOF

这些文件包含：
- rootfs.img
- $RAW_KERNEL
- $RAW_INITRD
- README.md

直接将这些文件导入 UTM 即可。
EOF

  echo "本地输出已写入：$OUT_DIR/"
fi

echo "全部完成。"
