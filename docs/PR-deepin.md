# PR: 补齐 SQLite WAL-reset 修复（3.46.1）

## 标题

```
fix(cve-less): backport upstream WAL-reset corruption fix (3.51.3 / 3.50.7 family)
```

## 描述

### 问题

上游 SQLite 在 3.51.3（2026-03-13）修复了一个 WAL 数据损坏缺陷，即所谓 **WAL-reset bug**：

<https://sqlite.org/wal.html#walresetbug>

- 影响范围：**3.7.0（2010）至 3.51.2**，即包含本仓库的 3.46.1
- 触发条件：WAL 模式下，同一文件有两个以上连接（不同线程或进程），在 checkpoint 与写事务 wrap WAL 的瞬间交错
- 后果：checkpoint 误判已回填的页数，已提交事务的部分页永远不落到主库文件，**数据库静默损坏**
- 上游 backport：3.44.6、3.50.7；3.51.3 起为主线修复

### 为什么这条漏了

本仓库 `debian/patches/series` 里已有 30 条补丁，2026 年的
CVE-2026-11822 / 11824 / 119371–119379 / 119591 / 39113 / 50812 / 50813 全部在列。
这条修复**没有 CVE 编号**（SUSE、Debian、Ubuntu 的 changelog 都只写
"Fix the WAL-reset database corruption bug"），所以按 CVE 号扫描的流程会整条漏掉它。

这不是本仓库独有的情况：Debian bookworm（3.40.1-2+deb12u2）与 trixie（3.46.1-7+deb13u2）
同样没有合入；Ubuntu 已经 backport（LP #2171337），SUSE 已把 SLE 12/15 与 Micro 6.0 升到 3.51.3。

### 上游对严重度的定性（引用原文，不放大）

> It is unlikely to occur in common use. […] the occurrence rate of this problem in the wild
> appears to be less than or equal to the expected occurrence rate of SSD malfunctions
> and/or cosmic-ray hits.

即：**罕见**。但它是真实的：Tailscale 因此经历了约 6 个月的线上不稳定才定位到根因
（<https://tailscale.com/blog/sqlite-wal-reset-bug>），Antithesis 也用故障注入做了独立复现
（<https://antithesis.com/blog/2026/wal-reset-bug>）。

所以这个 PR 的诉求不是"救火"，而是**把一条已经有官方 backport 的修复补齐**。

### 补丁

`debian/patches/56-WAL-reset.patch`，三处改动：

1. `src/wal.c` — `walCheckpoint()` 里，获取 `WAL_READ_LOCK(0)` 之后，比对
   `walIndexHdr(pWal)->aSalt` 与 `pWal->hdr.aSalt`。不一致说明 header 被读入后 WAL 已被写者
   wrap（此时 `nBackfill` 已被置 0），继续 backfill 会按旧的 `mxFrame` 写页 —— 直接跳过本轮。
2. `src/wal.c` — 增加 `sqlite3FaultSim(660)`，供回归用例在 checkpoint 中途插入竞争写入。
3. `test/walrestart.test` — 上游随修复发布的回归用例，原样收录。

来源：
- trunk: <https://sqlite.org/src/info/7168988acbec2d8d>
- 3.44 分支 cherry-pick: `2af8439a0c22c652`（"omits testing infrastructure"）
- 交叉参照：Ubuntu jammy 的 `0019-Avoid-an-obscure-race-condition-between-a-checkpoint.patch`

### 验证（x86_64, gcc 13.3）

在 `sqlite3_3.46.1.orig.tar.xz`（Debian pool 原件）上：

```
$ patch -p1 --dry-run -i 56-WAL-reset.patch
checking file src/wal.c
checking file test/walrestart.test
# 零 reject，零 fuzz
```

A/B 回归（同一份 `test/walrestart.test`，`make testfixture` 构建）：

| | 结果 |
|---|---|
| 3.46.1 原样 | **2 errors out of 7** — 1.3 expected `[0 45 0]` got `[0 45 45]`；1.4 expected `[0 58 58]` got `[0 45 45]` |
| 3.46.1 + 本补丁 | **0 errors out of 7** |

功能回归 16 项全过（FTS3/4/5、trigram 中文子串、JSON1、RTREE、MATH、窗口函数、CTE、
`UPDATE ... LIMIT`、BLOB、4 写 + 4 读线程并发 WAL、`PRAGMA integrity_check`），`integrity_check=ok`。

完整输出与构建指纹（gcc 版本、configure 参数、`src/wal.c` 补丁前后 sha256、产物 sha256）在
本仓库 `evidence/`。

### 已验证 / 未验证

| 架构 | 状态 |
|---|---|
| x86_64（WSL2 Ubuntu 24.04） | ✅ 补丁应用 + 编译 + A/B 回归 |
| aarch64（UOS 20, 内核 5.10.97） | ✅ 用户机实机：自编译 3.54.1 替换系统库，294 个进程重启后正常，并发压测通过 |
| 真实 UOS x64 / loongarch64 | ⬜ 未测，欢迎回报 |

### 请求

1. 若接受：请合入 `debian/patches/` + `series`，changelog 建议条目：

```
  * Backport upstream fix for the WAL-reset database corruption bug
    (present in 3.7.0 through 3.51.2, fixed in 3.51.3; backports: 3.44.6, 3.50.7)
    https://sqlite.org/wal.html#walresetbug
```

2. 若不接受（例如计划直接升到 3.51.3+），麻烦回一句说明，我把本仓库标注为该分支不再需要。

补丁有任何适配问题请直接指出，我按你们的分支基线重做。
