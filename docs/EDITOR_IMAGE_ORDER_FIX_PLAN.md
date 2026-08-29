# 私人书架：编辑图片顺序“选中→删除→保存”回归修复与网络挂载复验 执行方案

> 文档状态：**已执行完成**（2026-08-30，全部阶段通过并推送 GitHub）
> 编写日期：2026-08-30
> 当前版本：`v1.1.0+2`，HEAD `f1f3fa2`
> 远程仓库：`https://github.com/shitmof/private-manga-reader.git`（`main`）
> 当前工作区：`lib/screens/editor_screen.dart` 已修改（+55/-23）、`test/editor_screen_test.dart` 新增（+193，未跟踪）

---

## 0. 项目整体理解（已完成摸底）

- **产品**：私人书架——Flutter 手机漫画/插画阅读器。本地优先、私有、无损；三层结构：书架 → 漫画 → 图片。
- **技术栈与架构**：
  - SQLite（sqflite，`user_version=3`）：`comics` / `comic_items` / `assets` / `network_sources` / `remote_books` / `remote_pages` / `settings`。
  - `AppController`（状态门面）→ `LibraryRepository` / `NetworkRepository` → `AppDatabase`。
  - 本地导入走 SHA-256 去重；网络书源（WebDAV/OPDS/SMB）只读挂载，密码存 Android 安全存储。
  - UI 主题 `ShelfColors`（`lib/theme.dart`），干净克制风格；三列编辑网格 + 底部工具栏。
- **主流程**：书架 `LibraryScreen` → 详情 `ComicDetailScreen`（“开始阅读”/“编辑图片顺序”）→ 阅读器 `ReaderScreen` 或编辑器 `EditorScreen`。
- **编辑页现状**：`LongPressDraggable` 拖动排序、正序/倒序/添加/删除/封面工具栏、保存/取消；支持追加导入。
- **测试现状**：13 项自动化（`repository_test.dart` 11 项 + `app_smoke_test.dart` 2 项）全部通过；模拟器 4 台在线（`emulator-5554`、`emulator-5556` + 2 台无线 adb 设备）。
- **GitHub 约定**（`docs/ROLLBACK.md`）：私有仓库为源码与安装包远端回退点；`backup-*` / `checkpoint-*` 标签按日期命名；常规提交直接上 `main` 并 `--follow-tags`。

## 1. 问题与根因（已定位）

用户路径：漫画详情 → 开始阅读 → 编辑图片顺序 → 点选其中一张 → 无法删除、无法保存。

**根因**：`LibraryRepository.loadItems()` 返回 `rows.map(...).toList(growable: false)` —— **固定长度列表**；编辑页 `_load()` 直接把它赋给 `_items`。点选切换选中本身成功，但：

- 删除：`_items.removeWhere(...)` → 抛 `UnsupportedError: Cannot remove from a fixed-length list`
- 拖动：`_items.removeAt(...)` / `_items.insert(...)` → 同一异常

因此手机上表现为“选中后无法点击删除/保存”。修复方向：**进入编辑页时创建可变草稿列表**；草稿只存在于内存，只有点“保存”才写库，取消不触碰原始数据。

## 2. 方法与想法

1. **workspace-first 定位**：已核对共享状态（`00_统一总纲`、`02_项目总目录`、`09_CURRENT_STATE`）与项目文档（README / PRODUCT_SPEC / ACCEPTANCE / ROLLBACK / V1.1 计划）。
2. **TDD 垂直切片**：一条测试锁定一条用户行为（RED → GREEN → REFACTOR），不做横向“先写全部测试再写全部实现”。
3. **最小修复**：只把“既有编辑能力”补到可达、可感知：
   - 整张卡片明确可点（`HitTestBehavior.opaque` + 语义按钮）；
   - 标题栏显示“已选择 N 张”；
   - 删除前弹确认（说明“保存后生效、其他漫画引用不受影响”）；
   - 保留原工具栏与整体布局/配色，不改 UI 风格。
4. **数据语义**：删除只改编辑草稿与 `_removedIds`；保存才调 `applyItemEdits`；取消回滚已追加图片并离开，不改变原图。
5. **双通道验证**：自动化（widget 测试 + 全量 `flutter analyze` / `flutter test`）+ 模拟器人工路径；网络挂载复验独立并行（与编辑修复无关）。
6. **GitHub 优先**：所有变更经私有仓库提交/推送，回退点先打标签；不直接改动用户已装软件。

## 3. 完整执行流程

### 阶段 0 —— GitHub 回退点（最先执行）

1. `git status` 确认工作区（保留未提交的修复工作，不 stash、不 reset）。
2. 在干净 HEAD（`f1f3fa2` = `v1.1.0` 稳定提交）打注释标签并推送：

   ```powershell
   git tag -a backup-pre-editor-fix-20260830 -m "回退点：编辑页选中删除修复前的 v1.1.0 稳定提交"
   git push origin backup-pre-editor-fix-20260830
   ```

3. 记录标签指向的 commit 哈希，写入本次执行记录。

### 阶段 1 —— TDD 固定回归（RED 已发生，补齐 GREEN 与缺失用例）

- **RED 证据（已记录）**：回归测试在旧代码上失败——图片缺少明确、可测试的选择语义；删除/拖动触发 fixed-length 崩溃，与用户感受一致。
- **当前工作区改动即 GREEN 候选**：
  - `lib/screens/editor_screen.dart`：可变草稿列表（`List<ComicItemRecord>.of(items)`）、选择语义与计数、删除确认对话框；
  - `test/editor_screen_test.dart`：真实界面路径（点选第 2 张 → “已选择 1 张” → 删除弹确认 → 确认 → 2/1000 → 保存 → 数据库剩 2 张）。
- **补齐用例（一条行为一个用例，先 RED 后 GREEN）**：
  - a. 取消路径：点选 → 删除 → 确认 → 点“取消”退出 → 数据库仍为 3 张（原图不变）；
  - b. 重进持久：保存后重新打开编辑页显示 `2 / 1000 张`；
  - c. 拖动排序回归：拖动第 3 张到第 1 位不崩溃（fixed-length 的另一半回归）。
- 每个用例跑通 RED→GREEN 后再进入下一用例。

### 阶段 2 —— 全量自动化验证

- `flutter analyze`：0 问题。
- `flutter test`：13 项既有测试 + 新增回归用例全部通过。
- 若中文工程路径触发分析服务兼容问题：创建英文 Junction 作为临时入口（当前未发现现存 Junction），不影响产物。

### 阶段 3 —— 模拟器人工验证（编辑路径）

设备：`emulator-5554`（其余 3 台保持在线备用）。

1. 构建 Debug APK（仅本机验证用，不发布）。
2. 全新安装并造数：新建漫画 → 导入 3 张测试图。
3. 详情页 → 开始阅读 → 编辑图片顺序。
4. 点选第 2 张 → 顶部出现“已选择 1 张”→ 底部“删除”可用 → 点删除 → 确认框 → 确认 → 显示 `2 / 1000 张`。
5. 点“保存”→ 返回详情 → 再次进入“编辑图片顺序”→ 仍为 `2 / 1000 张`（重新进入保持）。
6. 再验证取消路径：点选 → 删除 → 确认 → 点“取消”退出 → 数据库仍 2 张。
7. 顺手验证拖动排序不崩溃。

### 阶段 4 —— 网络挂载复验（并行）

自动化已覆盖（`repository_test.dart`）：WebDAV 扫描 + 按需缓存 + 页面自然顺序、OPDS 数字自然排序、跨来源凭据隔离。

设备回路（`emulator-5556`）：

1. 本机启动临时 HTTP OPDS/WebDAV 服务（Python 脚本 + 3 页 CBZ 样本，端口固定）。
2. 模拟器 App → 网络书库 → 添加来源 → 挂载 → 扫描。
3. 打开 3 页远程漫画：按需下载/解压、阅读进度只写本地。
4. 清缓存 / 解除挂载：本地索引与缓存归零，远端 CBZ 保持不变。
5. 结果与证据追加到 `docs/ACCEPTANCE.md`；验证脚本保留为 `docs/verification/` 或按你的意愿删除。

### 阶段 5 —— 提交到 GitHub（不直接改已装软件）

按仓库约定分组合并提交到 `main`（`--follow-tags`）：

1. `test: 编辑页选中、确认删除与保存回归测试`（`test/editor_screen_test.dart`）
2. `fix: 编辑页使用可变草稿列表并补选择反馈与删除确认`（`lib/screens/editor_screen.dart`）
3. `docs: 编辑页修复执行方案与网络挂载复验记录`（本方案、`docs/ACCEPTANCE.md`、`docs/ROLLBACK.md` 标签清单）

推送后核对远程 `main` 与新增标签。

### 阶段 6 —— 共享状态与交付汇报（workspace-first 收尾）

- 更新 `04_Agent统一记忆/09_CURRENT_STATE.md`（`focus_project` = 私人漫画阅读器，`focus_task` = 编辑页回归修复）。
- 汇报：改了哪些文件、验证的实际结果、产物位置、剩余风险与未验证边界。

## 4. 需要你批准 / 决策的点

| # | 决策点 | 默认建议 |
|---|---|---|
| 1 | 回退点标签名 `backup-pre-editor-fix-20260830` | 沿用现有 `backup-*` 约定，默认执行 |
| 2 | 提交方式：直接在 `main` | 沿用 `ROLLBACK.md` 约定；如需 feature branch 请说明 |
| 3 | 版本号与 APK | **默认不 bump 版本、不发布新 APK/Release**（只把源码+文档推 GitHub）；如需 `v1.1.1+3` + Release APK 请说明 |
| 4 | 模拟器分工 | `emulator-5554` 编辑路径、`emulator-5556` 网络挂载 |
| 5 | 临时网络服务 | 本机 Python 起 OPDS/WebDAV，验证后按你意愿保留或删除 |

## 5. 风险与边界

- 不改 UI 风格、不动产品上限（1000 张）、不碰数据库 schema / 迁移。
- 不删除、不迁移用户已装 App 数据；模拟器验证全部使用测试数据。
- 不读取/写入网络密码，凭据不入仓库；不推送任何私密文件。
- 若 `flutter analyze/test` 遇中文路径问题：建英文 Junction 处理，产物不受影响。
- 回退方式（`ROLLBACK.md`）：`git switch --detach backup-pre-editor-fix-20260830`，不做 `git reset --hard`。
- 手机数据回退仍以升级前导出的 `.mangabackup` 为准。

---

**批准后我将从阶段 0（打回退点标签并推送）开始，按阶段 1→6 顺序执行，并在每阶段给出可核对证据。**
