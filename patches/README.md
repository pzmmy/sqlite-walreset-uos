# patches/ — 给发行版维护者

## 文件

| 文件 | 说明 |
|---|---|
| `56-WAL-reset.patch` | **主交付物**。适配 3.46.1 的 WAL-reset 修复，可直接进 `debian/patches/` |
| `reference-ubuntu-jammy-0019.patch` | 参照物：Ubuntu jammy 已发布的同源 backport（针对 3.37/3.40），仅作 provenance，不要直接应用 |

## 应用

```bash
cp 56-WAL-reset.patch debian/patches/
echo 56-WAL-reset.patch >> debian/patches/series
dpkg-buildpackage -b -uc -us
```

## 补丁来源

- upstream trunk: <https://sqlite.org/src/info/7168988acbec2d8d>
- 3.44 分支 cherry-pick: `2af8439a0c22c652`（"omits testing infrastructure"）
- 3.44.6 / 3.50.7 为官方 backport 版本
- Ubuntu jammy 同源补丁：LP #2171337

## 改动

1. `src/wal.c` `walCheckpoint()`：拿到 `WAL_READ_LOCK(0)` 后比对 live salt 与读入时的
   `pWal->hdr.aSalt`，不一致则说明 WAL 已被写者 wrap（`nBackfill` 已置 0），跳过本轮 backfill。
2. `src/wal.c`：新增 `sqlite3FaultSim(660)` 测试钩子。
3. `test/walrestart.test`：上游回归用例，原样收录（版权声明随原文）。

## 验证

在 `sqlite3_3.46.1.orig.tar.xz`（Debian pool 原件）上 `patch -p1` 零 reject；
`make testfixture` 后 A/B 回归：未打补丁 2 errors/7，打补丁 0 errors/7。
详见 `../evidence/`。
