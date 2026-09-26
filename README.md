# Mac 干净卸载器 (AppUninstaller)

一个极简的 macOS 应用卸载工具：选择（或拖入）应用，自动扫描其关联残留文件，一键全部移入废纸篓。

纯 Swift + AppKit 原生实现，无第三方依赖，单文件 `main.swift`。

## 功能

- 扫描 `/Applications` 与 `~/Applications` 下所有应用，后台计算各应用占用大小
- 选中应用后自动搜索关联残留：Application Support、Caches、Logs、Containers、Group Containers、Preferences、LaunchAgents/Daemons、receipts 等
- 支持把 `.app` 直接拖进窗口卸载
- 卸载统一走废纸篓（`FileManager.trashItem`），可随时恢复
- 无权限删除的系统目录项，自动分类并引导（管理员密码 / 完全磁盘访问权限）
- 关闭窗口后再点 Dock 图标可重新打开窗口

## 构建

```bash
# 注意：必须显式指定部署目标，否则 Xcode/工具链默认 minos 可能高于本机系统版本，
# 导致 LaunchServices 拒绝启动（kLSIncompatibleSystemVersionErr）
swiftc -O -target arm64-apple-macos12.0 main.swift -o AppUninstaller
```

打包成 App：

```bash
mkdir -p AppUninstaller.app/Contents/MacOS AppUninstaller.app/Contents/Resources
cp Info.plist AppUninstaller.app/Contents/
cp AppUninstaller AppUninstaller.app/Contents/MacOS/
cp AppIcon.icns  AppUninstaller.app/Contents/Resources/
printf 'APPL????' > AppUninstaller.app/Contents/PkgInfo
codesign --force -s - AppUninstaller.app
```

## 命令行测试模式

```bash
swiftc -O -DUNINSTALL_TEST main.swift -o uninstall-test
./uninstall-test /Applications/SomeApp.app          # 只扫描，列出关联文件
./uninstall-test /Applications/SomeApp.app --trash  # 扫描并移入废纸篓
```

## 说明

- 系统要求：macOS 12+
- 删除均为废纸篓操作，不直接 `rm`
