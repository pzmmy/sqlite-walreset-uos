#!/bin/bash
# 替换系统 libsqlite3.so.0 为自编译新版（UOS / Deepin ARM64）
#
# 前置：必须先跑 build_sqlite.sh 且影子测试全绿
# 安全：自动备份原库 + 生成回滚脚本 + 二次确认
#
# 用法：sudo bash replace_system_sqlite.sh --yes
set -euo pipefail

LIBDIR=/usr/lib/aarch64-linux-gnu
NEWLIB=/tmp/sqlite_build/libsqlite3.so.0.8.7
BACKUP_DIR=/data/work/backup/sqlite-$(date +%Y%m%d-%H%M%S)
STAMP=$(date +%Y%m%d-%H%M%S)

if [ "${1:-}" != "--yes" ]; then
    echo "⚠  即将替换系统共享库 $LIBDIR/libsqlite3.so.0"
    echo "   系统里有 294 个进程链这个库，替换后需重启才能完全生效。"
    echo "   确认已通过影子测试，然后执行： sudo bash $0 --yes"
    exit 1
fi

[ "$(id -u)" = "0" ] || { echo "✗ 需要 root"; exit 1; }
[ -f "$NEWLIB" ] || { echo "✗ 新库不存在: $NEWLIB（先跑 build_sqlite.sh）"; exit 1; }

echo "=== 1) 校验新库 ==="
readelf -d "$NEWLIB" | grep -q "libsqlite3.so.0" || { echo "✗ soname 不正确"; exit 1; }
# 注意：不能写成 `strings ... | grep -q`。在 set -o pipefail 下，
# grep -q 命中后立即退出会让 strings 收到 SIGPIPE（退出码 141），
# 整个管道因此被判为失败，误报"缺失特性"。先把输出落到文件再查。
FEATLIST=$(mktemp)
strings "$NEWLIB" | sort -u > "$FEATLIST"
for f in ENABLE_FTS5 ENABLE_FTS4 ENABLE_FTS3 ENABLE_RTREE ENABLE_COLUMN_METADATA \
         ENABLE_MATH_FUNCTIONS ENABLE_SESSION ENABLE_PREUPDATE_HOOK \
         ENABLE_UNLOCK_NOTIFY ENABLE_LOAD_EXTENSION ENABLE_DBSTAT_VTAB \
         ENABLE_STMTVTAB ENABLE_FTS3_TOKENIZER; do
    if ! grep -qx "$f" "$FEATLIST"; then
        echo "✗ 缺少编译特性: $f"
        rm -f "$FEATLIST"
        exit 1
    fi
done
rm -f "$FEATLIST"
echo "  ✓ soname 与 13 项关键特性校验通过"

echo "=== 2) 备份原库 ==="
mkdir -p "$BACKUP_DIR"
cp -a "$LIBDIR/libsqlite3.so.0.8.6" "$BACKUP_DIR/" 2>/dev/null || \
    cp -a "$(readlink -f $LIBDIR/libsqlite3.so.0)" "$BACKUP_DIR/"
ls -la "$BACKUP_DIR/" | sed 's/^/  /'
ORIG=$(basename "$(readlink -f $LIBDIR/libsqlite3.so.0)")
echo "  原库文件名: $ORIG"

echo "=== 3) 安装新库 ==="
install -m 644 "$NEWLIB" "$LIBDIR/libsqlite3.so.0.8.7"
ln -sfn libsqlite3.so.0.8.7 "$LIBDIR/libsqlite3.so.0"
ln -sfn libsqlite3.so.0.8.7 "$LIBDIR/libsqlite3.so"
ldconfig
echo "  ✓ 已安装并更新链接"
ls -la "$LIBDIR"/libsqlite3.so* | sed 's/^/  /'

echo "=== 4) 生成回滚脚本 ==="
cat > /data/work/scripts/sqlite/rollback_sqlite.sh <<EOF
#!/bin/bash
# 一键回滚 SQLite 到系统原版（$STAMP）
set -e
echo "回滚中：恢复 $ORIG"
cp -a "$BACKUP_DIR/$ORIG" "$LIBDIR/$ORIG"
ln -sfn "$ORIG" "$LIBDIR/libsqlite3.so.0"
ln -sfn "$ORIG" "$LIBDIR/libsqlite3.so"
rm -f "$LIBDIR/libsqlite3.so.0.8.7"
ldconfig
echo "✓ 已回滚，当前版本："
sqlite3 --version
echo "  注意：已运行的程序需重启才会重新加载旧库。"
EOF
chmod +x /data/work/scripts/sqlite/rollback_sqlite.sh
echo "  ✓ /data/work/scripts/sqlite/rollback_sqlite.sh"

echo "=== 5) 验证（新进程）==="
sqlite3 --version
python3.11 -c "import sqlite3; print('  python sqlite3:', sqlite3.sqlite_version)"
python3 -c "import sqlite3; print('  python3.7 sqlite3:', sqlite3.sqlite_version)" 2>/dev/null || true

echo
echo "=== 完成 ==="
echo "  下次重启后，全系统 294 个进程都会用上新库。"
echo "  出问题就一条命令回滚： sudo bash /data/work/scripts/sqlite/rollback_sqlite.sh"
echo "  若系统起不来：进 tty 或恢复模式执行上面同一条命令。"
