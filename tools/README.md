# tools/ — 用户侧临时缓解（非主交付物）

这些脚本用于**官方出包之前**在单机上把系统 SQLite 换掉。属于权宜之计，
发行版维护者不会采纳这种方式（替换全系统共享库的风险由用户承担，不由打包方承担）。

正路是 `../patches/`：让官方出一条包。

## 脚本

| 脚本 | 作用 |
|---|---|
| `build_sqlite.sh <版本号>` | 下载源码前需自行准备 amalgamation；编译 + 影子测试（`LD_LIBRARY_PATH`，不碰系统库） |
| `replace_system_sqlite.sh --yes` | 备份原库 + 生成回滚脚本，然后替换 |
| `rollback_sqlite.sh` | 回滚 |
| `make_deb.sh` | 打独立 deb，装到 `/usr/local/lib`，不与 dpkg 抢文件 |

## 硬约束

1. **先跑影子测试**，全绿再替换。测试期间系统库完全没动，测挂了删目录即可。
2. 编译特性必须与原库逐项对齐：
   `strings /usr/lib/<arch>-linux-gnu/libsqlite3.so.0 | grep -E '^ENABLE_|^MAX_|^THREADSAFE'`
   少一个宏就让某些程序丢功能（最典型：少了 FTS5，全文搜索直接报错）。
3. 替换后 `/usr/bin/sqlite3` 会报 `SQLite header and source version mismatch` 并退出 ——
   因为 CLI 自己内嵌了编译时版本号。用同一份源码重编 CLI 装到 `/usr/local/bin`，
   **不要覆盖 `/usr/bin/sqlite3`**（dpkg 管的文件）。
4. 建议在能物理接触机器时操作。图形界面起不来时 `Ctrl+Alt+F3` 进 tty 回滚。

## 实测范围

仅 aarch64 / UOS 20（内核 5.10.97）验证过运行。x86_64 的补丁编译验证见 `../evidence/`，
但"替换系统库"这一步在 x86_64 未做。
