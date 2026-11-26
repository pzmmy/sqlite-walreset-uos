#!/bin/bash
# 把自编译的新版 SQLite 打成 .deb 包，便于在 UOS/Deepin ARM64 社区分发
#
# 设计取舍：包内文件装到 /usr/local/lib（而非覆盖 /usr/lib），原因——
#   1. 不与 dpkg 管理的 libsqlite3-0 争抢文件，不会出现 overwrite 报错
#   2. 通过 /etc/ld.so.conf.d/00-sqlite-local.conf 让动态链接器优先命中
#   3. 卸载（apt remove）即完全回滚，系统原库从未被改动
#
# 用法：bash make_deb.sh 3540100
set -euo pipefail

VER="${1:-3540100}"
SRC=/tmp/sqlite_build/libsqlite3.so.0.8.7
PKG_NAME="sqlite3-local-arm64"
PKG_VER="3.54.1"
BUILD="/tmp/sqlite_deb"
ARCH="$(dpkg --print-architecture)"

[ -f "$SRC" ] || { echo "✗ 找不到编译产物 $SRC（先跑 build_sqlite.sh）"; exit 1; }

rm -rf "$BUILD"
mkdir -p "$BUILD/DEBIAN" \
         "$BUILD/usr/local/lib" \
         "$BUILD/etc/ld.so.conf.d" \
         "$BUILD/usr/share/doc/$PKG_NAME"

echo "=== 1) 放文件 ==="
install -m 644 "$SRC" "$BUILD/usr/local/lib/libsqlite3.so.0.8.7"
ln -sfn libsqlite3.so.0.8.7 "$BUILD/usr/local/lib/libsqlite3.so.0"
ln -sfn libsqlite3.so.0.8.7 "$BUILD/usr/local/lib/libsqlite3.so"
# 00- 前缀保证 ldconfig 最先读它
echo "/usr/local/lib" > "$BUILD/etc/ld.so.conf.d/00-sqlite-local.conf"

cp /data/work/scripts/sqlite/README.md "$BUILD/usr/share/doc/$PKG_NAME/README.md" 2>/dev/null || true

echo "=== 2) 控制文件 ==="
cat > "$BUILD/DEBIAN/control" <<EOF
Package: $PKG_NAME
Version: $PKG_VER-1
Section: libs
Priority: optional
Architecture: $ARCH
Maintainer: pzmmy <124426051@qq.com>
Description: Newer SQLite shared library for UOS/Deepin on ARM64
 Ships SQLite $PKG_VER into /usr/local/lib to work around the WAL-reset
 data-corruption bug present in the distribution's SQLite 3.39.3
 (fixed upstream in 3.44.6 / 3.50.7 / 3.51.3+).
 .
 Installed under /usr/local/lib via a dedicated ld.so.conf.d entry, so the
 distribution's own libsqlite3-0 package is never modified and removing this
 package restores the previous behaviour completely.
 .
 Compile-time feature flags are aligned with the UOS 3.39.3 build
 (FTS3/FTS4/FTS5, RTREE, JSON, MATH, COLUMN_METADATA, SESSION, ...).
EOF

cat > "$BUILD/DEBIAN/postinst" <<'EOF'
#!/bin/sh
set -e
ldconfig
echo "sqlite3-local-arm64: installed. Verify with:"
echo "  python3 -c 'import sqlite3; print(sqlite3.sqlite_version)'"
echo "Restart applications (or reboot) so they load the new library."
EOF

cat > "$BUILD/DEBIAN/prerm" <<'EOF'
#!/bin/sh
set -e
# 删除 conf 后再 ldconfig，使链接器回到系统原库
rm -f /etc/ld.so.conf.d/00-sqlite-local.conf
ldconfig
EOF

chmod 755 "$BUILD/DEBIAN/postinst" "$BUILD/DEBIAN/prerm"

echo "=== 3) 打包 ==="
OUT="/data/work/scripts/sqlite/${PKG_NAME}_${PKG_VER}-1_${ARCH}.deb"
dpkg-deb --build --root-owner-group "$BUILD" "$OUT" >/dev/null
echo "  ✓ $OUT ($(du -h "$OUT" | cut -f1))"
dpkg-deb -I "$OUT" | head -12

echo
echo "=== 4) 本地校验（不安装）==="
dpkg-deb -c "$OUT" | sed 's/^/  /'

echo
echo "=== 安装方式 ==="
echo "  sudo dpkg -i $OUT"
echo "  验证: python3 -c 'import sqlite3; print(sqlite3.sqlite_version)'"
echo "  卸载: sudo apt remove $PKG_NAME"
