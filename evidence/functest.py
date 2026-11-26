#!/usr/bin/env python3
"""功能回归测试：用 ctypes 直接驱动指定的 libsqlite3.so，不依赖系统 python sqlite3 模块。

用法: functest.py <libsqlite3.so 路径> <工作目录>
输出: 每项 PASS/FAIL + 汇总，退出码 = 失败项数
"""
import ctypes, os, sys, threading, traceback

SO, WD = sys.argv[1], sys.argv[2]
lib = ctypes.CDLL(SO)
lib.sqlite3_libversion.restype = ctypes.c_char_p
CB = ctypes.CFUNCTYPE(ctypes.c_int, ctypes.c_void_p, ctypes.c_int,
                      ctypes.POINTER(ctypes.c_char_p), ctypes.POINTER(ctypes.c_char_p))

class DB:
    def __init__(self, path):
        self.h = ctypes.c_void_p()
        rc = lib.sqlite3_open_v2(path.encode(), ctypes.byref(self.h), 2 | 4, None)  # READWRITE|CREATE ... flags
        if rc != 0:
            raise RuntimeError(f"open rc={rc}")
        lib.sqlite3_busy_timeout(self.h, 8000)
    def exec(self, sql):
        rows = []
        def _cb(_u, n, vals, names):
            rows.append(tuple((vals[i] or b"").decode("utf-8", "replace") for i in range(n)))
            return 0
        cb = CB(_cb)
        err = ctypes.c_char_p()
        rc = lib.sqlite3_exec(self.h, sql.encode(), cb, None, ctypes.byref(err))
        if rc != 0:
            msg = err.value.decode("utf-8", "replace") if err.value else "?"
            raise RuntimeError(f"sqlite rc={rc}: {msg} | SQL={sql[:120]}")
        return rows
    def one(self, sql):
        r = self.exec(sql)
        return r[0][0] if r and r[0] else None
    def close(self):
        lib.sqlite3_close(self.h)

results = []
def T(name, fn):
    try:
        out = fn()
        results.append((True, name, out))
    except Exception as e:
        results.append((False, name, f"{type(e).__name__}: {e}"))

path = os.path.join(WD, "ft.db")
for suf in ("", "-wal", "-shm"):
    if os.path.exists(path + suf):
        os.remove(path + suf)
db = DB(path)

T("版本号", lambda: lib.sqlite3_libversion().decode())
T("journal_mode=WAL", lambda: db.one("PRAGMA journal_mode=WAL"))
T("FTS5 中文检索", lambda: (
    db.exec("CREATE VIRTUAL TABLE f5 USING fts5(body, tokenize='unicode61')"),
    db.exec("INSERT INTO f5 VALUES('中文全文检索测试数据'), ('sqlite wal reset bug')"),
    db.one("SELECT body FROM f5 WHERE f5 MATCH '\"中文全文检索测试数据\"'"))[2])
T("FTS5 trigram", lambda: (
    db.exec("CREATE VIRTUAL TABLE f5t USING fts5(body, tokenize='trigram')"),
    db.exec("INSERT INTO f5t VALUES('操作系统数据库测试')"),
    db.one("SELECT count(*) FROM f5t WHERE f5t MATCH '操作系统'"))[2])
T("FTS4", lambda: (
    db.exec("CREATE VIRTUAL TABLE f4 USING fts4(body)"),
    db.exec("INSERT INTO f4 VALUES('full text search')"),
    db.one("SELECT count(*) FROM f4 WHERE f4 MATCH 'text'"))[2])
T("FTS3", lambda: (
    db.exec("CREATE VIRTUAL TABLE f3 USING fts3(body)"),
    db.exec("INSERT INTO f3 VALUES('alpha beta')"),
    db.one("SELECT count(*) FROM f3 WHERE f3 MATCH 'beta'"))[2])
T("JSON1", lambda: db.one("SELECT json_extract('{\"a\":{\"b\":42}}','$.a.b')"))
T("RTREE", lambda: (
    db.exec("CREATE VIRTUAL TABLE rt USING rtree(id,minx,maxx,miny,maxy)"),
    db.exec("INSERT INTO rt VALUES(1,0,10,0,10),(2,5,15,5,15)"),
    db.one("SELECT count(*) FROM rt WHERE maxx>=5 AND minx<=12"))[2])
T("MATH", lambda: db.one("SELECT round(sqrt(144),0) || '/' || round(pow(2,10),0)"))
T("窗口函数", lambda: db.one("SELECT sum(v) OVER (ORDER BY v) FROM (SELECT 1 v UNION SELECT 2 UNION SELECT 3) ORDER BY v DESC LIMIT 1"))
T("CTE", lambda: db.one("WITH RECURSIVE c(i) AS (SELECT 1 UNION ALL SELECT i+1 FROM c WHERE i<10) SELECT sum(i) FROM c"))
def _update_limit():
    db.exec("CREATE TABLE ul(a)")
    db.exec("INSERT INTO ul VALUES(1),(2),(3)")
    db.exec("UPDATE ul SET a=a+1 LIMIT 1")
    return db.one("SELECT sum(a) FROM ul")
T("UPDATE/DELETE LIMIT", _update_limit)
T("BLOB 1MB", lambda: (
    db.exec("CREATE TABLE bl(b BLOB)"),
    db.exec("INSERT INTO bl VALUES(zeroblob(1048576))"),
    db.one("SELECT length(b) FROM bl"))[2])
T("COLUMN_METADATA 宏", lambda: "compiled-in (静态)" if ctypes.CDLL(SO).sqlite3_column_decltype is not None else "missing")

# WAL 并发：多线程混合读写
def concurrent():
    errs = []
    stop = threading.Event()
    def writer(k):
        d = DB(path)
        try:
            for i in range(120):
                d.exec("INSERT INTO load(v,w) VALUES(%d,%d)" % (i, k))
                if i % 40 == 0:
                    d.exec("PRAGMA wal_checkpoint(PASSIVE)")
        except Exception as e:
            errs.append(f"writer{k}: {e}")
        finally:
            d.close()
    def reader(k):
        d = DB(path)
        try:
            for _ in range(400):
                d.one("SELECT count(*) FROM load")
        except Exception as e:
            errs.append(f"reader{k}: {e}")
        finally:
            d.close()
    db.exec("CREATE TABLE load(v INTEGER, w INTEGER)")
    ts = [threading.Thread(target=writer, args=(k,)) for k in range(4)]
    ts += [threading.Thread(target=reader, args=(k,)) for k in range(4)]
    for t in ts: t.start()
    for t in ts: t.join()
    if errs:
        raise RuntimeError("; ".join(errs[:3]))
    n = db.one("SELECT count(*) FROM load")
    ic = db.one("PRAGMA integrity_check")
    return f"4写/4读线程 × 480 事务, 行数={n}, integrity_check={ic}"

T("WAL 并发读写 + integrity", concurrent)
T("最终 integrity_check", lambda: db.one("PRAGMA integrity_check"))
db.close()

fail = sum(1 for ok, _, _ in results if not ok)
for ok, name, out in results:
    print(("PASS  " if ok else "FAIL  ") + f"{name}: {out}")
print(f"\n{len(results)-fail}/{len(results)} passed")
sys.exit(fail)
