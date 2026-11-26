# 构建与验证记录

生成时间: 2026-11-26T10:41:01+08:00
构建主机: Young-notebook / Linux 6.18.58.1-microsoft-standard-WSL2 / x86_64
gcc: gcc (Ubuntu 13.3.0-6ubuntu2~24.04.1) 13.3.0
make: GNU Make 4.3

上游源码: sqlite3_3.46.1.orig.tar.xz (8,456,776 B)
  来源: https://deb.debian.org/debian/pool/main/s/sqlite3/sqlite3_3.46.1.orig.tar.xz
  VERSION: 3.46.1
  src/wal.c sha256 (补丁前): d4a104b5f3cb807e026a9dbcdb77519358b06b66f76cb6b6ef70e3793379dd62
  src/wal.c sha256 (补丁后): 9ed0f05463c4fc73939741366e778bdfed5e95e1edadae770be5760cde786f19

configure 参数:
  ./configure --disable-tcl --enable-shared --disable-static \
    --enable-fts3 --enable-fts4 --enable-fts5 --enable-rtree \
    --enable-session --enable-update-limit
  CFLAGS="-O2 -fPIC"

产物: libsqlite3.so.0.8.6 (1,614,736 B)
  sha256: 7ad95f99657ad02415a4463551f6f8d14f24a65edda1f7b9b84e720c1af7a11e
  SONAME               libsqlite3.so.0
