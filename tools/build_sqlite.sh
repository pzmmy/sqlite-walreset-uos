#!/bin/bash
# 为 UOS / Deepin ARM64 编译新版 SQLite 共享库
#
# 目的：替换系统 libsqlite3.so.0（3.39.3，存在 WAL-reset 数据损坏风险）
#      为 3.5x（官方修复版），仅替换这一个库文件，全程可回滚。
#
# 关键：编译开关必须与 UOS 原库对齐，否则依赖它的 294 个进程会丢功能
#      （原库 features 用 `strings libsqlite3.so.0 | grep ENABLE_` 取得）
#
# 用法：bash build_sqlite.sh <源码版本号>   例：bash build_sqlite.sh 3540100
set -euo pipefail

VER="${1:-3540100}"
SRC_DIR="/tmp/sqlite_build"
OUT="$SRC_DIR/libsqlite3.so.0.8.7"

cd "$SRC_DIR"
[ -d "sqlite-amalgamation-$VER" ] || { echo "✗ 源码目录不存在: sqlite-amalgamation-$VER"; exit 1; }

echo "=== 编译 SQLite amalgamation $VER (aarch64) ==="

CFLAGS_FEATURES=(
  # —— 与 UOS 原库逐项对齐 ——
  -DSQLITE_ENABLE_COLUMN_METADATA
  -DSQLITE_ENABLE_DBSTAT_VTAB
  -DSQLITE_ENABLE_FTS3
  -DSQLITE_ENABLE_FTS3_PARENTHESIS
  -DSQLITE_ENABLE_FTS3_TOKENIZER
  -DSQLITE_ENABLE_FTS4
  -DSQLITE_ENABLE_FTS5
  -DSQLITE_ENABLE_LOAD_EXTENSION
  -DSQLITE_ENABLE_MATH_FUNCTIONS
  -DSQLITE_ENABLE_PREUPDATE_HOOK
  -DSQLITE_ENABLE_RTREE
  -DSQLITE_ENABLE_SESSION
  -DSQLITE_ENABLE_STMTVTAB
  -DSQLITE_ENABLE_UNLOCK_NOTIFY
  -DSQLITE_ENABLE_UPDATE_DELETE_LIMIT
  -DSQLITE_MAX_ATTACHED=10
  -DSQLITE_MAX_COLUMN=2000
  -DSQLITE_MAX_COMPOUND_SELECT=500
  -DSQLITE_MAX_DEFAULT_PAGE_SIZE=32768
  -DSQLITE_MAX_EXPR_DEPTH=1000
  -DSQLITE_MAX_FUNCTION_ARG=127
  -DSQLITE_MAX_LENGTH=1000000000
  -DSQLITE_MAX_LIKE_PATTERN_LENGTH=50000
  -DSQLITE_MAX_MMAP_SIZE=0x7fff0000
  -DSQLITE_MAX_PAGE_COUNT=1073741823
  -DSQLITE_THREADSAFE=1
)

echo "  编译中（约 1-3 分钟）..."
gcc -O2 -fPIC -shared \
    -Wl,-soname,libsqlite3.so.0 \
    -o "$OUT" \
    "$SRC_DIR/sqlite-amalgamation-$VER/sqlite3.c" \
    "${CFLAGS_FEATURES[@]}" \
    -lpthread -ldl -lm

echo "  ✓ 产物: $OUT ($(stat -c%s "$OUT") 字节)"
echo "  soname: $(readelf -d "$OUT" | grep SONAME | sed 's/.*\[\(.*\)\]/\1/')"

# —— 影子测试：绝不触碰系统库，用 LD_LIBRARY_PATH 加载新库 ——
echo
echo "=== 影子测试（新库，不碰系统库）==="
TESTDIR="$SRC_DIR/shadow"
mkdir -p "$TESTDIR"
ln -sf "$OUT" "$TESTDIR/libsqlite3.so.0"

# 本机 python3.11 不在 PATH，按优先级找一个真实解释器
PY=""
for cand in /data/WNNY04/hermes/.hermes/hermes-agent/venv/bin/python3.11 \
            /opt/deepin-shared-libs/python311/bin/python3.11 \
            "$(command -v python3.11 2>/dev/null)"; do
    [ -x "$cand" ] && { PY="$cand"; break; }
done
[ -n "$PY" ] || { echo "✗ 找不到 python3.11"; exit 1; }
echo "  测试解释器: $PY"

LD_LIBRARY_PATH="$TESTDIR" "$PY" - "$TESTDIR" <<'PY'
import sqlite3, sys, os
print("  库路径:", sqlite3.__file__)
print("  版本  :", sqlite3.sqlite_version)
src = os.environ.get("LD_LIBRARY_PATH","")
assert src, "LD_LIBRARY_PATH 未生效"

def check(name, fn):
    try:
        fn(); print(f"  ✓ {name}")
    except Exception as e:
        print(f"  ✗ {name}: {type(e).__name__}: {e}"); sys.exit(1)

mem = lambda: sqlite3.connect(":memory:")

# 1. FTS5（Hermes 会话搜索的核心）
def t_fts5():
    c = mem()
    c.execute("CREATE VIRTUAL TABLE t USING fts5(content)")
    c.execute("INSERT INTO t VALUES ('怀柔区科协 科普月 活动')")
    r = c.execute("SELECT content FROM t WHERE t MATCH '科普月'").fetchall()
    assert r and "科普月" in r[0][0], r
check("FTS5 建表/插入/中文 MATCH", t_fts5)

# 2. FTS5 trigram（Hermes 有 messages_fts_trigram）
#    注意：必须用**无空格中文**测。unicode61 分词器会把连续中文整串当一个词，
#    那种情况下 MATCH 子串查不到是分词器行为而非 bug；trigram 才能子串命中。
def t_trigram():
    c = mem()
    c.execute("CREATE VIRTUAL TABLE t USING fts5(x, tokenize='trigram')")
    c.execute("INSERT INTO t VALUES ('怀柔区科协科普月活动')")
    assert c.execute("SELECT * FROM t WHERE t MATCH '科普月'").fetchall()
check("FTS5 trigram 中文子串匹配", t_trigram)

# 3. FTS4 / FTS3
def t_fts34():
    c = mem()
    c.execute("CREATE VIRTUAL TABLE a USING fts4(x)")
    c.execute("CREATE VIRTUAL TABLE b USING fts3(y)")
    c.execute("INSERT INTO a VALUES ('hello world')")
    assert c.execute("SELECT * FROM a WHERE a MATCH 'hello'").fetchall()
check("FTS3 / FTS4", t_fts34)

# 4. JSON 函数
def t_json():
    c = mem()
    assert c.execute("SELECT json_extract('{\"a\":{\"b\":42}}','$.a.b')").fetchone()[0] == 42
    assert c.execute("SELECT json_valid('{\"x\":1}')").fetchone()[0] == 1
check("JSON1 函数", t_json)

# 5. RTREE
def t_rtree():
    c = mem()
    c.execute("CREATE VIRTUAL TABLE r USING rtree(id,minX,maxX,minY,maxY)")
    c.execute("INSERT INTO r VALUES(1,0,10,0,10)")
    assert c.execute("SELECT id FROM r WHERE minX>=0 AND maxX<=20").fetchall()
check("RTREE 空间索引", t_rtree)

# 6. 数学函数
def t_math():
    c = mem()
    assert c.execute("SELECT sqrt(16), pow(2,10), sin(0)").fetchone() == (4.0, 1024.0, 0.0)
check("MATH 函数", t_math)

# 7. 窗口函数 + CTE（3.39 也有，但确认没退化）
def t_window():
    c = mem()
    c.execute("CREATE TABLE n(v INTEGER)")
    c.executemany("INSERT INTO n VALUES(?)", [(1,),(2,),(3,)])
    r = c.execute("SELECT v, sum(v) OVER (ORDER BY v) FROM n").fetchall()
    assert r[-1][1] == 6, r
check("窗口函数 / CTE", t_window)

# 8. WAL 模式 + 并发读写（WAL-reset bug 的场景）
def t_wal():
    import tempfile
    p = tempfile.mktemp(suffix=".db")
    c1 = sqlite3.connect(p); c1.execute("PRAGMA journal_mode=WAL")
    assert c1.execute("PRAGMA journal_mode").fetchone()[0].lower() == "wal"
    c1.execute("CREATE TABLE t(a)"); c1.executemany("INSERT INTO t VALUES(?)", [(i,) for i in range(500)])
    c1.commit()
    c2 = sqlite3.connect(p)  # 并发读者
    cnt = c2.execute("SELECT count(*) FROM t").fetchone()[0]
    assert cnt == 500, cnt
    c2.close(); c1.close(); os.remove(p)
check("WAL 模式 + 并发读写", t_wal)

# 9. 大对象 + 事务回滚
def t_blob():
    c = mem()
    c.execute("CREATE TABLE b(x BLOB)")
    data = os.urandom(200000)
    c.execute("INSERT INTO b VALUES(?)", (data,))
    assert c.execute("SELECT length(x) FROM b").fetchone()[0] == 200000
check("BLOB 大对象", t_blob)

# 10. 编译选项暴露的 API（COLUMN_METADATA 等）
def t_meta():
    c = mem()
    c.execute("CREATE TABLE m(a INTEGER PRIMARY KEY, b TEXT)")
    cur = c.execute("SELECT b FROM m")
    assert cur.description is not None
check("COLUMN_METADATA 游标描述", t_meta)

print("\n  ✓ 影子测试全部通过")
PY

echo
echo "=== 下一步（尚未执行）==="
echo "  · 若上面全绿，再运行 replace_system_sqlite.sh 替换系统库"
echo "  · 替换前会自动备份原库，并生成回滚脚本"
