#!/bin/bash
# 一键回滚 SQLite 到系统原版（20261125-215135）
set -e
echo "回滚中：恢复 libsqlite3.so.0.8.6"
cp -a "/data/work/backup/sqlite-20261125-215135/libsqlite3.so.0.8.6" "/usr/lib/aarch64-linux-gnu/libsqlite3.so.0.8.6"
ln -sfn "libsqlite3.so.0.8.6" "/usr/lib/aarch64-linux-gnu/libsqlite3.so.0"
ln -sfn "libsqlite3.so.0.8.6" "/usr/lib/aarch64-linux-gnu/libsqlite3.so"
rm -f "/usr/lib/aarch64-linux-gnu/libsqlite3.so.0.8.7"
ldconfig
echo "✓ 已回滚，当前版本："
sqlite3 --version
echo "  注意：已运行的程序需重启才会重新加载旧库。"
