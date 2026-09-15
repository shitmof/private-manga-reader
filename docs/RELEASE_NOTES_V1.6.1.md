# 拾画阁 v1.6.1 发布说明

发布日期：2026-09-15
Android 版本：`1.6.1+8`

本版集中修复 v1.6.0 验收中确认的问题，其中包含一项**必须升级**的安装缺陷。

## 重要：修复签名不一致导致无法覆盖升级

v1.6.0 的 APK 与 v1.5.0 **不是同一把密钥签的**，导致已装 v1.5.0 的设备无法就地升级
（会报 `INSTALL_FAILED_UPDATE_INCOMPATIBLE`），只能卸载重装并丢失书架数据。

根因：Gradle 把 debug keystore 解析为 `$ANDROID_USER_HOME/.android/debug.keystore`
（旧变量是 `$ANDROID_SDK_HOME`），而**不是** `$HOME/.android`。
当 `ANDROID_USER_HOME=E:\Android\.android` 时，用的是 `E:\Android\.android\debug.keystore`；
v1.5.0 实际使用的是 `C:\Users\<用户>\.android\debug.keystore`——两者证书不同。

修复：
- 新增 `android/key.properties` 显式指定密钥（**不进版本库**），并在
  `android/` 下放置 `shihuage-release.keystore`（同样被 `.gitignore` 排除）；
- 构建脚本把解析结果打印到构建日志，避免"用了哪把密钥"不可见；
- `key.properties` 里显式指定了 `storeFile` 却找不到时**直接构建失败**，绝不静默回退
  （静默回退正是产生不可升级包的原因）；
- 解析 `key.properties` 时会剥离 UTF-8 BOM——Windows 的 `Set-Content -Encoding UTF8`
  和不少编辑器会写 BOM，而 BOM 会污染第一行的键名，使 `storeFile` 失效。

**本版证书 SHA-256 = `3724690E26BAE1597AD10221C10F2B2B15ADE2A5BFDBAF408834DC46EAACE1A5`，
与 v1.5.0 一致。** 已装 v1.5.0 的设备可以直接覆盖安装并保留数据。

> 如果你当前装的是 **v1.6.0**（错误密钥签名的那个包），仍需先卸载一次才能装上 v1.6.1；
> 从 v1.6.1 起，后续版本都能正常覆盖升级。

## 修复：设置页开关不刷新 / 互相覆盖

- **现象**：点击开关后功能已生效，但同一页面上开关仍显示旧状态，必须退出重进才更新；
  且在同一页面连续改两个开关时，第二次会把第一次的设置覆盖回去。
- **根因**：设置页是独立路由，不订阅 controller，因此不会因偏好变化而重建；
  各开关回调闭包又捕获了进入页面时的那份 `preferences` 快照。
  另外原先把 `setState` 放在 `await` 之后，落盘一旦慢，界面就会长时间停留在旧状态。
- **修复**：统一走新的更新入口——始终基于**最新**快照计算新值，
  并在调用后**同步**刷新界面（落盘异步进行，不阻塞 UI）。

## 修复：退出普通漫画会解除全局截屏保护

- **现象**：开启无痕模式后，进入任意**非私密**漫画阅读页再退出，截屏保护被解除，
  但设置里仍显示"无痕模式已开启"。
- **根因**：阅读页只在私密漫画时申请截屏保护，但 `dispose()` **无条件**释放。
  计数被凭空减一后归零，于是把无痕模式的保护一并解除。
- **修复**：用 `_holdsGuard` 记录本页是否真的申请过，严格成对申请/释放。

## 其他修复

- 退出阅读页时的亮度还原改为吞掉平台异常。
  该方法在部分 ROM 或非 Android 环境下没有实现，
  而 `dispose` 里的 `unawaited` 位于 try/catch 之外，会抛出未处理的异步异常。

## 验证

- `dart analyze`：0 诊断；`flutter test`：**60/60 通过**。
- 新增 3 个针对性回归测试（`test/settings_and_privacy_test.dart`），
  并**验证过它们在缺陷代码上确实会失败**：
  在 `updatePreferences` 中注入 1500ms 模拟真机慢落盘后，
  "开关立即刷新"与"连续修改不互相覆盖"两项均按预期失败。
- 修复了一处既有测试的时序脆弱点：`library_screen_test.dart` 中"标记私密后应消失"
  原先固定等待 500ms，并行跑全量时偶发不足导致失败，已改为轮询等待条件成立。
- 证书已用 `apksigner` 核验与 v1.5.0 一致。

## 安装包

- `shihuage-v1.6.1-android.apk`
- SHA-256：见对应 Release 资产
- 证书 SHA-256：`3724690E26BAE1597AD10221C10F2B2B15ADE2A5BFDBAF408834DC46EAACE1A5`
- `versionName=1.6.1` / `versionCode=8`，最低 Android 7.0（API 24）
- 兼容 ABI：`arm64-v8a`、`armeabi-v7a`、`x86_64`

## 尚未处理（v1.6.0 起已确认，本版未修）

- 「ZIP 内套 CBZ」的嵌套压缩包仍会被拒绝导入。
- 在文件夹内导入漫画时，归属仍是顶层书架而非当前文件夹。
- 一次导入只创建一本漫画，尚无自动分册逻辑。
- 应用不接收分享（`ACTION_SEND`）的压缩包，仅响应「用拾画阁打开」。
- `android:usesCleartextTraffic="true"` 仍为全局放行。
- 数据库缺少 `onDowngrade` 处理，降级后再升级存在启动失败风险。
- 大文件物化缓存只保留了最近 6 个，尚无界面上的手动清理入口。
