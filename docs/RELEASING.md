# 发布流程

## 原则

- 完成功能、修复问题、调整文档或资源时，只创建普通 commit。
- 不因为一次提交、一次构建或一次安装而自动增加版本号。
- 只有用户明确要求“发布版本”时，才执行正式发布。
- 每个正式版本必须在 `CHANGELOG.md` 中记录新增、修改和修复；没有内容的分类可以省略。

## 正式发布步骤

1. 确认用户明确要求发布，并确定版本号。
2. 在 `lib/AppInfo.ahk` 中同时更新 `AppInfo.Version` 与 `Ahk2Exe-SetVersion`。
3. 在 `CHANGELOG.md` 顶部加入该版本的发布日期及新增、修改、修复说明。
4. 运行完整构建：

   ```powershell
   pwsh -NoProfile -File .\build.ps1 -Package
   ```

5. 验证源码自检、编译后自检、隔离烟雾测试、`dist` 产物、ZIP 内容、文件版本和 SHA-256。
6. 创建包含版本号和发布说明的 release commit。
7. 创建 annotated tag `v<版本号>`；tag 说明应概括本次发布内容。
8. 推送 release commit 与 tag，并在 GitHub Release 上传 `dist` 中的版本化 ZIP。
9. 不修改或覆盖已有 tag。需要修订时使用新的补丁版本。
