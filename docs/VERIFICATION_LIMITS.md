# 拾画阁验证限制说明

本文件记录**无法用自动化测试覆盖**的行为，以及原因。
目的在于避免后来者重复尝试同样的无效验证，也避免把未验证项误当成已验证。

每条都注明：结论、依据、以及可行的替代验证方式。

---

## 1. 书架隐私过滤无法在 widget 层证伪

**结论**：`library_screen.dart` 中 `_visibleComics` 的
`_LibraryScope.all => comic.folderId == null && !comic.isPrivate`
是一条防御性判断，**其保护对象在正常数据流下不会走到它面前**，
因此写不出「移除它就会失败」的回归测试。该判断保留，但列为**未验证**。

**排查过程与依据**（均为诊断打印实测，非推断）：

1. **私密分组内的漫画没有 root 范围的书架条目**
   `moveComicsToFolder` 只改 `comics.folder_id`，分组内漫画仅在分组卡片的
   四宫格里展示，不单独列在主书架。诊断输出：
   `entries=folder@private|comic@root`（分组内漫画无条目）。
   因此「分组内漫画不得出现在主书架」恒真，与过滤无关。

2. **私密分组在 root 范围由层级过滤排除**
   `visibleFolders` 在 `_LibraryScope.all` 下已 `where((f) => !f.isPrivate)`，
   分组卡片根本不构建，封面/名称/预览都不渲染。

3. **标记漫画为私密时，上游已改 scope**
   `createComic` 会按 `is_private` 写入 `shelf_entries.scope`
   （private / root）；`setComicPrivate` 只改 `comics` 表。
   而 `_gridEntries` 在 root 范围要求 `entry.scope == 'root'`，
   私密漫画仍在 `scope='private'`，在此就被挡掉。诊断输出：
   `entries=comic:783e@private|comic:b53e@root`，
   移除判断后渲染结果不变，仅剩公开漫画。

**替代验证方式**：需要在真机上构造两条数据路径——
①存在 `folder_id != null` 且 `is_private == 1` 的漫画；
②存在 `scope='root'` 且 `is_private == 1` 的 shelf entry。
两者都需要直接操作数据库，可用备份导入构造，再观察主书架。
未执行。

---

## 2. v1.5.0 在部分设备上方向异常

**结论**：v1.5.0 在阴阳师模拟器（SM-A5560，Android 15）上，
设备为 `720x1280` 竖屏而截图输出 `1280x720`，`SurfaceOrientation: 1`。
导致 `adb shell input tap` 的坐标空间与截图不一致，**无法盲点坐标做自动化操作**。

**依据**：`wm size` 与 `screencap` 输出尺寸不一致；实测点击 FAB 未命中。

**影响**：v1.5.0 的界面自动化不可靠。录制/截图验收应在 v1.6.x 上进行
（该版本已修复方向问题）。

---

## 3. `screenrecord` 会随父 shell 退出而结束

**结论**：用 `Start-Process` 直接启动 `adb shell screenrecord`，
父进程一退出录制即结束（实测只录到 2.58 秒，而 `--time-limit` 设为 18 秒）。

**正确做法**：在后台作业中启动，并在**同一会话内**等待到时限后再结束，
之后用 `adb pull` 导出。

**另注**：`adb pull` 对含非 ASCII 字符的目标路径会失败，
需切到目标目录后用相对路径。
