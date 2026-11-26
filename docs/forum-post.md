# 论坛发布稿（统信 UOS 论坛 / 深度论坛）

## 标题（建议，任选其一）

- 【建议】UOS 自带 SQLite 3.39.3 存在 WAL 数据损坏风险，附 arm64 修复方案（已实测）
- 系统里的 SQLite 可能正在悄悄损坏你的数据：3.39.3 的 WAL-reset bug 与一个可回滚的修复办法
- 统信/深度 SQLite 缺一条已发布的修复：我做了 backport 补丁并验证过
- 手把手把 UOS 的 SQLite 从 3.39.3 升到 3.54.1（arm64，可一键回滚）

## 帖子正文（直接复制）

---

### 一、先说结论

先分清版本，别一锅端：

- **我现在这台 UOS 20（eagle 1070）**：SQLite **3.39.3**（`libsqlite3.so.0.8.6`）
- **Deepin 当前打包基线**：**3.46.1**（`3.46.1-8deepin6`，2026-11-10 提交）

两个版本都在受影响区间内。SQLite 官方确认的 **WAL-reset bug** 影响 **3.7.0（2010）到 3.51.2**，
在 **3.51.3（2026-03-13）** 修复，并给旧分支出了 backport：**3.44.6** 和 **3.50.7**。

现象是：WAL 模式下同一数据库有两个以上连接并发读写时，checkpoint 与写事务交错，
**已提交事务的部分数据页永远不落到主库文件** —— 不崩溃、不报错，
`PRAGMA integrity_check` 之外你几乎无从察觉。

**但要说实话**：上游自己把这个概率定得很低 ——
"unlikely to occur in common use"，并称野外发生率"小于等于 SSD 故障或宇宙射线的预期发生率"。
所以它不是一个需要恐慌的问题。它值得处理的原因是另一件事：**修复早就有了，发行版只是没跟上。**

而 UOS 软件源里目前最高只到 `3.39.3.6-deepin1`，那是打包层面的补丁版本，
**并没有 backport WAL 修复**。也就是说：只靠 `apt upgrade` 是修不好的。

我在这台机器上（UOS arm64，内核 5.10.97）自己编译了 SQLite 3.54.1 替换系统库，
跑了完整的兼容性测试和并发压力测试，目前运行正常，并整理了可回滚的脚本。

### 二、怎么看自己有没有风险

```bash
# 看系统 SQLite 版本
sqlite3 --version
python3 -c "import sqlite3; print(sqlite3.sqlite_version)"
ls -la /usr/lib/aarch64-linux-gnu/libsqlite3.so*

# 看有多少程序在用它（本机实测 294 个）
sudo lsof 2>/dev/null | grep -c libsqlite3
```

只要版本落在 3.7.0–3.51.2 之间，就带着这个 bug（3.39.3、3.46.1 都在内）。

受影响的不只是"数据库应用"——浏览器、笔记、聊天记录、开发工具、甚至部分系统组件都用 SQLite。
风险取决于你的使用场景：有程序在 WAL 模式下多连接并发读写，才有命中的可能。
它很罕见 —— 罕见不代表不存在，Tailscale 就是被它连续坑了约 6 个月才定位到根因
（tailscale.com/blog/sqlite-wal-reset-bug）。

### 三、为什么之前没人修（三条路都是堵的）

| 思路 | 结论 |
|---|---|
| `apt` 升级 | 源里最高 3.39.3.6，未 backport WAL 修复 |
| `pip install pysqlite3-binary` | 该项目**只发布 x86_64 轮子**，arm64 装不了 |
| 自己编译替换 | ✅ 可行（本方案） |

所以这事不是没人想到，是 arm64 用户一直没有现成方案。

还有个更直接的对照 —— **别的发行版已经跟进了**：

| 发行版 | WAL-reset 修复 |
|---|---|
| Ubuntu jammy / resolute | 已 backport（LP #2171337） |
| SUSE SLE 12/15、Micro 6.0 | 已升到 3.51.3 |
| Debian bookworm / trixie | 未合 |
| **Deepin / UOS 打包** | **未合** —— 30 条 CVE 补丁齐全，唯独缺这条（因为它没有 CVE 号） |

### 四、我的做法（核心就一个思路：只换一个文件，且可回滚）

保留发行版的使用方式，只把 `libsqlite3.so.0` 指向新编译的库，原库原封不动留在旁边。

**关键点 1：编译特性必须与原库逐项对齐。**
`libsqlite3.so.0` 被几百个程序依赖，少一个编译宏就会让某些程序功能缺失
（最典型：少了 `FTS5`，全文搜索直接报错）。原库启用了哪些特性可以这样看：

```bash
strings /usr/lib/aarch64-linux-gnu/libsqlite3.so.0 | grep -E "^ENABLE_|^MAX_|^THREADSAFE"
```

UOS 3.39.3 启用了 15 项（FTS3/4/5、RTREE、JSON、MATH、COLUMN_METADATA、SESSION…），
**逐项对齐，一个都不能少。**

**关键点 2：必须先影子测试，通过了才碰系统库。**
用 `LD_LIBRARY_PATH` 让新库只在新进程里生效，这样测试期间系统库完全没动，
测挂了直接删目录即可。我测了 10 项：FTS5 中文检索、trigram 中文子串、FTS3/4、
JSON、RTREE、数学函数、窗口函数、WAL 并发读写、BLOB、游标元数据。
另外用真实的 109MB 数据库做了并发压力测试（13 线程混跑、1285 次写入，
`integrity_check` 通过、零异常）。

**关键点 3：替换会自动备份 + 生成回滚脚本。**

### 五、替换后一定会遇到的一个坑（重要）

换完库之后，`sqlite3` 命令会报：

```
SQLite header and source version mismatch
```

然后**直接退出**，连 `SELECT 1` 都不执行。

原因：`/usr/bin/sqlite3` 动态链接这个库，但它自己内嵌了编译时的版本号（3.39.3），
一比对发现不一致就拒绝工作。

解决办法是把 CLI 也用同一份源码重编一个，装到 `/usr/local/bin`：

```bash
gcc -O2 -o sqlite3-new shell.c sqlite3.c \
    -DSQLITE_ENABLE_FTS5 -DSQLITE_ENABLE_FTS4 -DSQLITE_ENABLE_FTS3 \
    -DSQLITE_ENABLE_RTREE -DSQLITE_ENABLE_COLUMN_METADATA \
    -DSQLITE_ENABLE_MATH_FUNCTIONS -DSQLITE_THREADSAFE=1 \
    -lpthread -ldl -lm
sudo install -m 755 sqlite3-new /usr/local/bin/sqlite3
hash -r && sqlite3 -version     # 应显示 3.54.1
```

**不要覆盖 `/usr/bin/sqlite3`**，那是 dpkg 管的文件，覆盖会让包校验失败。

### 六、风险提示（务必看）

1. 这是替换**全系统共享库**。新库若有问题，依赖它的程序（含开机自启的桌面组件）
   可能全部异常，极端情况影响进图形界面。
2. 所以请务必**先跑影子测试**，全绿再替换。
3. 建议在**能物理接触到机器**的时候操作，不要纯远程环境动手。
4. 生产/办公关键机器，建议先做完整数据备份。
5. 我只在自己这台 UOS arm64 上验证过；x86_64 请自行编译（脚本通用）。

### 七、回滚方式

```bash
sudo bash rollback_sqlite.sh
```

如果图形界面已经起不来：`Ctrl+Alt+F3` 切到 tty 登录后执行同一条命令，
或用 UOS 的 A/B 恢复分区（`/boot/deepin-ab-recovery/`）引导。

### 八、更希望官方来做

个人替换系统库终究是权宜之计，而且风险不小（换的是全系统共享库）。

所以我把这件事往前推了一步：**把上游的 backport 补丁做出来了**，直接对应 Deepin/UOS 的
3.46.1 打包基线，一条 `debian/patches/56-WAL-reset.patch`，改 `src/wal.c` 两处 +
带上游回归用例。

验证结果（x86_64，同一份官方回归用例）：

| | `test/walrestart.test` |
|---|---|
| 3.46.1 原样 | 2 errors / 7 |
| 3.46.1 + 补丁 | **0 errors / 7** |

官方那边只要合一条补丁、加一行 changelog 就行，不用跟着我换系统库。
补丁、构建指纹、A/B 原始输出都在仓库里：https://github.com/pzmmy/sqlite-walreset-uos

WAL-reset bug 的危害在于**数据静默损坏**——不崩溃、不报错、发现时已经晚了。
这类问题比"程序闪退"更值得优先处理。

### 九、脚本与包

仓库里有两层东西：

- `patches/` —— 给发行版维护者的 backport 补丁（**推荐走这条**）
- `tools/` —— 官方出包之前的临时缓解：编译脚本、替换脚本、回滚脚本、打包脚本，
  外加 arm64 的 .deb（装到 `/usr/local/lib`，不与系统包冲突，卸载即回滚）

- GitHub：https://github.com/pzmmy/sqlite-walreset-uos

有需要的朋友可以直接用，也欢迎反馈其它架构/版本的验证结果。

---

## 发帖注意事项（给我自己看的备忘）

- 统信论坛：bbs.chinauos.com，需 Union ID / 微信扫码登录
- 深度论坛：bbs.deepin.org
- 建议发在「系统使用 / 系统讨论」类板块
- 首次发帖可能需要审核，附上 GitHub 链接可提高可信度
