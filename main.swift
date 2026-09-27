import Cocoa

// MARK: - 工具函数
func fmtSize(_ b: UInt64) -> String {
    let kb = Double(b) / 1024
    if kb < 1 { return "\(b)B" }
    let mb = kb / 1024
    if mb < 1 { return String(format: "%.1fK", kb) }
    let gb = mb / 1024
    if gb < 1 { return String(format: "%.1fM", mb) }
    return String(format: "%.2fG", gb)
}

func dirSize(_ url: URL) -> UInt64 {
    let fm = FileManager.default
    var isDir: ObjCBool = false
    guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { return 0 }
    if !isDir.boolValue {
        let attrs = try? fm.attributesOfItem(atPath: url.path)
        return (attrs?[.size] as? NSNumber)?.uint64Value ?? 0
    }
    var total: UInt64 = 0
    if let en = fm.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]) {
        for case let f as URL in en {
            if let v = try? f.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
               v.isRegularFile == true {
                total += UInt64(v.fileSize ?? 0)
            }
        }
    }
    return total
}

func appIcon(_ path: String, size: CGFloat) -> NSImage {
    let img = NSWorkspace.shared.icon(forFile: path)
    img.size = NSSize(width: size, height: size)
    return img
}

// MARK: - 数据模型
struct AppEntry {
    let url: URL
    let name: String
    let bundleID: String
    let execName: String
    var size: UInt64 = 0
    var sizeLoaded = false
}

struct FoundFile {
    let url: URL
    var size: UInt64
    var checked: Bool
    let isAppBundle: Bool
}

let ownBundleID = Bundle.main.bundleIdentifier ?? ""

// MARK: - 应用扫描
func scanInstalledApps() -> [AppEntry] {
    let fm = FileManager.default
    var urls: [URL] = []
    for dir in [URL(fileURLWithPath: "/Applications"),
                fm.homeDirectoryForCurrentUser.appendingPathComponent("Applications")] {
        let items = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil, options: [])) ?? []
        urls += items.filter { $0.pathExtension.lowercased() == "app" }
    }
    var seen = Set<String>()
    var out: [AppEntry] = []
    for u in urls {
        let name = u.deletingPathExtension().lastPathComponent
        guard !seen.contains(name.lowercased()) else { continue }
        seen.insert(name.lowercased())
        let bundle = Bundle(url: u)
        let bid = bundle?.bundleIdentifier ?? "unknown.\(name)"
        let exec = bundle?.executablePath.map { URL(fileURLWithPath: $0).lastPathComponent } ?? name
        out.append(AppEntry(url: u, name: name, bundleID: bid, execName: exec))
    }
    return out.sorted { $0.name.lowercased() < $1.name.lowercased() }
}

// MARK: - 残留文件搜索
func findRelated(app: AppEntry) -> [FoundFile] {
    let fm = FileManager.default
    let home = fm.homeDirectoryForCurrentUser
    let lib = home.appendingPathComponent("Library")
    let bid = app.bundleID.lowercased()
    let nm = app.name.lowercased()
    var found: [URL] = []

    func children(_ dir: URL) -> [URL] {
        (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil, options: [])) ?? []
    }
    func add(_ u: URL) {
        guard fm.fileExists(atPath: u.path) else { return }
        if !found.contains(where: { $0.standardizedFileURL.path == u.standardizedFileURL.path }) {
            found.append(u)
        }
    }
    func addMatches(in dir: URL, match: (String) -> Bool) {
        for c in children(dir) where match(c.lastPathComponent.lowercased()) { add(c) }
    }

    // 1. 应用本体
    add(app.url)

    // 2. 按目录逐类匹配（目录名含 bundleID 或应用名）
    addMatches(in: lib.appendingPathComponent("Application Support")) { $0.contains(bid) || $0 == nm }
    addMatches(in: lib.appendingPathComponent("Caches")) { $0.contains(bid) || $0 == nm }
    addMatches(in: lib.appendingPathComponent("Logs")) { $0.contains(bid) || $0 == nm }
    addMatches(in: lib.appendingPathComponent("Saved Application State")) { $0.hasPrefix(bid) }
    addMatches(in: lib.appendingPathComponent("WebKit")) { $0.contains(bid) || $0 == nm }
    addMatches(in: lib.appendingPathComponent("HTTPStorages")) { $0.hasPrefix(bid) }
    addMatches(in: lib.appendingPathComponent("Containers")) { $0.contains(bid) }
    addMatches(in: lib.appendingPathComponent("Group Containers")) { $0.contains(bid) }
    addMatches(in: lib.appendingPathComponent("Application Scripts")) { $0.contains(bid) || $0 == nm }
    addMatches(in: lib.appendingPathComponent("Cookies")) { $0.hasPrefix(bid) }

    // 3. 偏好设置 plist（含 ByHost）
    addMatches(in: lib.appendingPathComponent("Preferences")) { $0 == "\(bid).plist" }
    addMatches(in: lib.appendingPathComponent("Preferences/ByHost")) { $0.hasPrefix(bid) && $0.hasSuffix(".plist") }

    // 4. 系统级目录（无权限时会保留并提示）
    addMatches(in: URL(fileURLWithPath: "/Library/Application Support")) { $0.contains(bid) || $0 == nm }
    addMatches(in: URL(fileURLWithPath: "/Library/LaunchAgents")) { $0.contains(bid) || $0.contains(nm) }
    addMatches(in: URL(fileURLWithPath: "/Library/LaunchDaemons")) { $0.contains(bid) || $0.contains(nm) }
    addMatches(in: URL(fileURLWithPath: "/Library/PrivilegedHelperTools")) { $0.contains(bid) || $0 == nm || $0 == app.execName.lowercased() }
    addMatches(in: URL(fileURLWithPath: "/private/var/db/receipts")) { $0.hasPrefix(bid) }

    // 5. 用户启动项：读取 plist 内容匹配 bundleID / 可执行名
    for dir in [lib.appendingPathComponent("LaunchAgents"),
                URL(fileURLWithPath: "/Library/LaunchAgents")] {
        for f in children(dir) where f.pathExtension == "plist" {
            if let data = try? Data(contentsOf: f),
               let obj = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) {
                let desc = String(describing: obj).lowercased()
                if desc.contains(bid) || desc.contains(nm) || desc.contains(app.execName.lowercased()) {
                    add(f)
                }
            }
        }
    }

    return found.map { FoundFile(url: $0, size: dirSize($0), checked: true, isAppBundle: $0.pathExtension == "app") }
        .sorted { $0.isAppBundle && !$1.isAppBundle }
}

// MARK: - 支持拖拽的根视图
final class DropView: NSView {
    var onDrop: ((URL) -> Void)?
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { hasApp(sender) ? .copy : [] }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { hasApp(sender) ? .copy : [] }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let items = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL],
              let url = items.first(where: { $0.pathExtension.lowercased() == "app" }) else { return false }
        onDrop?(url)
        return true
    }
    private func hasApp(_ sender: NSDraggingInfo) -> Bool {
        guard let items = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL] else { return false }
        return items.contains { $0.pathExtension.lowercased() == "app" }
    }
}

// MARK: - 主界面控制器
final class MainVC: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    var apps: [AppEntry] = []
    var files: [FoundFile] = []
    var selectedApp: AppEntry?
    private var scanGeneration = 0

    let appsTable = NSTableView()
    let filesTable = NSTableView()
    let headerIcon = NSImageView()
    let headerName = NSTextField(labelWithString: "选择左侧应用")
    let headerNameFont = NSFont.systemFont(ofSize: 16, weight: .semibold)
    let headerBid = NSTextField(labelWithString: "拖入 .app 也可卸载")
    let headerSize = NSTextField(labelWithString: "")
    let checkAllBtn = NSButton(checkboxWithTitle: "全选", target: nil, action: nil)
    let statusLabel = NSTextField(labelWithString: "")
    let spinner = NSProgressIndicator()
    let uninstallBtn = NSButton(title: "卸载到废纸篓", target: nil, action: nil)
    let rescanBtn = NSButton(title: "重新扫描", target: nil, action: nil)
    let emptyStack = NSStackView()

    override func loadView() {
        let root = DropView(frame: NSRect(x: 0, y: 0, width: 900, height: 620))
        root.wantsLayer = true

        // ---- 左侧侧栏（毛玻璃质感）----
        let sidebar = NSVisualEffectView()
        sidebar.translatesAutoresizingMaskIntoConstraints = false
        sidebar.material = .sidebar
        sidebar.blendingMode = .behindWindow
        sidebar.state = .active

        let sideTitle = NSTextField(labelWithString: "已安装应用")
        sideTitle.translatesAutoresizingMaskIntoConstraints = false
        sideTitle.font = NSFont.systemFont(ofSize: 12, weight: .semibold)
        sideTitle.textColor = .secondaryLabelColor

        // ---- 左侧应用列表 ----
        let appsScroll = NSScrollView()
        appsScroll.translatesAutoresizingMaskIntoConstraints = false
        appsScroll.hasVerticalScroller = true
        appsScroll.drawsBackground = false
        appsScroll.borderType = .noBorder
        let ac = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("app"))
        ac.width = 230
        appsTable.addTableColumn(ac)
        appsTable.headerView = nil
        appsTable.dataSource = self
        appsTable.delegate = self
        appsTable.rowHeight = 48
        appsTable.backgroundColor = .clear
        appsTable.style = .inset
        appsTable.identifier = NSUserInterfaceItemIdentifier("apps")
        appsScroll.documentView = appsTable

        sidebar.addSubview(sideTitle)
        sidebar.addSubview(appsScroll)

        // ---- 顶部详情头 ----
        let header = NSView()
        header.translatesAutoresizingMaskIntoConstraints = false
        header.wantsLayer = true
        header.layer?.backgroundColor = NSColor.underPageBackgroundColor.cgColor
        header.layer?.cornerRadius = 12

        headerIcon.translatesAutoresizingMaskIntoConstraints = false
        headerIcon.image = NSImage(systemSymbolName: "square.grid.2x2", accessibilityDescription: nil)

        let nameBid = NSStackView(views: [headerName, headerBid])
        nameBid.orientation = .vertical
        nameBid.alignment = .leading
        nameBid.spacing = 2
        nameBid.translatesAutoresizingMaskIntoConstraints = false
        headerName.font = NSFont.systemFont(ofSize: 17, weight: .semibold)
        headerBid.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        headerBid.textColor = .secondaryLabelColor

        headerSize.translatesAutoresizingMaskIntoConstraints = false
        headerSize.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        headerSize.textColor = .secondaryLabelColor
        headerSize.alignment = .right

        checkAllBtn.translatesAutoresizingMaskIntoConstraints = false
        checkAllBtn.target = self
        checkAllBtn.action = #selector(toggleAll)
        checkAllBtn.state = .on
        checkAllBtn.font = NSFont.systemFont(ofSize: 12)

        header.addSubview(headerIcon)
        header.addSubview(nameBid)
        header.addSubview(headerSize)
        header.addSubview(checkAllBtn)
        NSLayoutConstraint.activate([
            headerIcon.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 14),
            headerIcon.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            headerIcon.widthAnchor.constraint(equalToConstant: 48),
            headerIcon.heightAnchor.constraint(equalToConstant: 48),

            nameBid.leadingAnchor.constraint(equalTo: headerIcon.trailingAnchor, constant: 12),
            nameBid.centerYAnchor.constraint(equalTo: header.centerYAnchor),

            checkAllBtn.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -14),
            checkAllBtn.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            headerSize.trailingAnchor.constraint(equalTo: checkAllBtn.leadingAnchor, constant: -12),
            headerSize.centerYAnchor.constraint(equalTo: header.centerYAnchor),
        ])

        // ---- 右侧残留文件列表 ----
        let filesScroll = NSScrollView()
        filesScroll.translatesAutoresizingMaskIntoConstraints = false
        filesScroll.hasVerticalScroller = true
        filesScroll.borderType = .noBorder
        filesScroll.wantsLayer = true
        filesScroll.layer?.backgroundColor = NSColor.textBackgroundColor.cgColor
        filesScroll.layer?.cornerRadius = 12
        filesScroll.layer?.borderWidth = 1
        filesScroll.layer?.borderColor = NSColor.separatorColor.cgColor
        let fc1 = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("chk"))
        fc1.width = 30
        let fc2 = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("main"))
        fc2.width = 460
        let fc3 = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("size"))
        fc3.width = 90
        filesTable.addTableColumn(fc1)
        filesTable.addTableColumn(fc2)
        filesTable.addTableColumn(fc3)
        filesTable.headerView = nil
        filesTable.dataSource = self
        filesTable.delegate = self
        filesTable.rowHeight = 30
        filesTable.backgroundColor = .clear
        filesTable.style = .inset
        filesTable.identifier = NSUserInterfaceItemIdentifier("files")
        filesScroll.documentView = filesTable

        // ---- 空状态提示 ----
        let emptyIcon = NSImageView()
        emptyIcon.translatesAutoresizingMaskIntoConstraints = false
        if let sym = NSImage(systemSymbolName: "shippingbox", accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 44, weight: .light)) {
            emptyIcon.image = sym
        }
        emptyIcon.contentTintColor = .tertiaryLabelColor
        let emptyTitle = NSTextField(labelWithString: "选择左侧应用查看残留文件")
        emptyTitle.font = NSFont.systemFont(ofSize: 15, weight: .medium)
        emptyTitle.textColor = .secondaryLabelColor
        let emptySub = NSTextField(labelWithString: "或把 .app 直接拖进本窗口")
        emptySub.font = NSFont.systemFont(ofSize: 12)
        emptySub.textColor = .tertiaryLabelColor
        let emptyStack = self.emptyStack
        emptyStack.setViews([emptyIcon, emptyTitle, emptySub], in: .leading)
        emptyStack.orientation = .vertical
        emptyStack.alignment = .centerX
        emptyStack.spacing = 8
        emptyStack.translatesAutoresizingMaskIntoConstraints = false

        // ---- 底部栏 ----
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.font = NSFont.systemFont(ofSize: 12)
        statusLabel.lineBreakMode = .byTruncatingMiddle
        statusLabel.textColor = .secondaryLabelColor
        spinner.translatesAutoresizingMaskIntoConstraints = false
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isHidden = true
        uninstallBtn.translatesAutoresizingMaskIntoConstraints = false
        uninstallBtn.bezelStyle = .rounded
        uninstallBtn.controlSize = .large
        uninstallBtn.bezelColor = .systemRed
        uninstallBtn.target = self
        uninstallBtn.action = #selector(uninstallClicked)
        uninstallBtn.keyEquivalent = "\r"
        uninstallBtn.attributedTitle = NSAttributedString(string: "卸载到废纸篓", attributes: [
            .font: NSFont.systemFont(ofSize: 13, weight: .semibold),
            .foregroundColor: NSColor.white,
        ])
        rescanBtn.translatesAutoresizingMaskIntoConstraints = false
        rescanBtn.bezelStyle = .rounded
        rescanBtn.controlSize = .large
        rescanBtn.target = self
        rescanBtn.action = #selector(rescanClicked)

        let hint = NSTextField(labelWithString: "把 .app 拖进本窗口也可卸载 · 删除项均可从废纸篓恢复")
        hint.translatesAutoresizingMaskIntoConstraints = false
        hint.textColor = .tertiaryLabelColor
        hint.font = NSFont.systemFont(ofSize: 11)

        root.addSubview(sidebar)
        root.addSubview(header)
        root.addSubview(filesScroll)
        root.addSubview(emptyStack)
        root.addSubview(statusLabel)
        root.addSubview(spinner)
        root.addSubview(uninstallBtn)
        root.addSubview(rescanBtn)
        root.addSubview(hint)

        NSLayoutConstraint.activate([
            // 侧栏
            sidebar.topAnchor.constraint(equalTo: root.topAnchor),
            sidebar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            sidebar.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            sidebar.widthAnchor.constraint(equalToConstant: 250),
            sideTitle.topAnchor.constraint(equalTo: root.topAnchor, constant: 14),
            sideTitle.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor, constant: 16),
            appsScroll.topAnchor.constraint(equalTo: sideTitle.bottomAnchor, constant: 8),
            appsScroll.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor, constant: 6),
            appsScroll.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor, constant: -6),
            appsScroll.bottomAnchor.constraint(equalTo: sidebar.bottomAnchor, constant: -8),

            // 详情头
            header.topAnchor.constraint(equalTo: root.topAnchor, constant: 12),
            header.leadingAnchor.constraint(equalTo: sidebar.trailingAnchor, constant: 12),
            header.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
            header.heightAnchor.constraint(equalToConstant: 68),

            // 文件列表与空状态
            filesScroll.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 10),
            filesScroll.leadingAnchor.constraint(equalTo: header.leadingAnchor),
            filesScroll.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
            filesScroll.bottomAnchor.constraint(equalTo: statusLabel.topAnchor, constant: -8),
            emptyStack.centerXAnchor.constraint(equalTo: filesScroll.centerXAnchor),
            emptyStack.centerYAnchor.constraint(equalTo: filesScroll.centerYAnchor),

            // 底部栏（锚定右侧详情区，避免压在左侧应用列表上）
            hint.leadingAnchor.constraint(greaterThanOrEqualTo: sidebar.trailingAnchor, constant: 16),
            hint.leadingAnchor.constraint(equalTo: header.leadingAnchor),
            hint.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -10),

            statusLabel.leadingAnchor.constraint(equalTo: header.leadingAnchor),
            statusLabel.trailingAnchor.constraint(lessThanOrEqualTo: rescanBtn.leadingAnchor, constant: -10),
            statusLabel.bottomAnchor.constraint(equalTo: hint.topAnchor, constant: -6),

            spinner.leadingAnchor.constraint(equalTo: statusLabel.trailingAnchor, constant: 8),
            spinner.centerYAnchor.constraint(equalTo: statusLabel.centerYAnchor),

            rescanBtn.trailingAnchor.constraint(equalTo: uninstallBtn.leadingAnchor, constant: -10),
            rescanBtn.centerYAnchor.constraint(equalTo: uninstallBtn.centerYAnchor),
            uninstallBtn.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -14),
            uninstallBtn.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -14),
        ])

        root.registerForDraggedTypes([.fileURL])
        root.onDrop = { [weak self] url in self?.acceptDroppedApp(url) }

        view = root
        emptyStack.isHidden = false
        rescan()
    }

    // ---- 行视图构建 ----
    func makeRowCell(views: [NSView]) -> NSView {
        let cell = NSView()
        let stack = NSStackView(views: views)
        stack.orientation = .horizontal
        stack.spacing = 7
        stack.alignment = .centerY
        stack.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 6),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor, constant: -6),
            stack.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }

    // ---- 表格数据源 ----
    func numberOfRows(in tableView: NSTableView) -> Int {
        tableView.identifier?.rawValue == "apps" ? apps.count : files.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let id = tableView.identifier?.rawValue ?? ""
        if id == "apps" {
            let app = apps[row]
            let icon = NSImageView(image: appIcon(app.url.path, size: 28))
            let label = NSTextField(labelWithString: app.name)
            label.lineBreakMode = .byTruncatingTail
            label.font = NSFont.systemFont(ofSize: 13, weight: .medium)
            let sizeLabel = NSTextField(labelWithString: app.sizeLoaded ? fmtSize(app.size) : "计算中…")
            sizeLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular)
            sizeLabel.textColor = .secondaryLabelColor
            let vstack = NSStackView(views: [label, sizeLabel])
            vstack.orientation = .vertical
            vstack.alignment = .leading
            vstack.spacing = 2
            return makeRowCell(views: [icon, vstack])
        }
        switch tableColumn?.identifier.rawValue {
        case "chk":
            let btn = NSButton(checkboxWithTitle: "", target: self, action: #selector(checkToggled(_:)))
            btn.tag = row
            btn.state = files[row].checked ? .on : .off
            return btn
        case "size":
            let cell = NSTextField(labelWithString: fmtSize(files[row].size))
            cell.textColor = .secondaryLabelColor
            cell.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
            cell.alignment = .right
            cell.translatesAutoresizingMaskIntoConstraints = false
            let wrap = NSView()
            wrap.addSubview(cell)
            NSLayoutConstraint.activate([
                cell.trailingAnchor.constraint(equalTo: wrap.trailingAnchor, constant: -6),
                cell.centerYAnchor.constraint(equalTo: wrap.centerYAnchor),
            ])
            return wrap
        default:
            let f = files[row]
            let icon = NSImageView(image: appIcon(f.url.path, size: 16))
            let label = NSTextField(labelWithString: f.url.path)
            label.lineBreakMode = .byTruncatingMiddle
            label.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
            label.textColor = f.isAppBundle ? .labelColor : .secondaryLabelColor
            return makeRowCell(views: [icon, label])
        }
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard (notification.object as? NSTableView)?.identifier?.rawValue == "apps" else { return }
        let row = appsTable.selectedRow
        guard row >= 0, row < apps.count else { return }
        selectApp(apps[row])
    }

    @objc func checkToggled(_ sender: NSButton) {
        guard sender.tag < files.count else { return }
        files[sender.tag].checked = sender.state == .on
        updateHeaderSize()
    }

    @objc func toggleAll() {
        let on = checkAllBtn.state == .on
        for i in files.indices { files[i].checked = on }
        filesTable.reloadData()
        updateHeaderSize()
    }

    // ---- 选中应用 → 扫描残留 ----
    func selectApp(_ app: AppEntry) {
        selectedApp = app
        scanGeneration += 1
        let gen = scanGeneration
        files = []
        filesTable.reloadData()

        headerIcon.image = appIcon(app.url.path, size: 48)
        headerName.stringValue = app.name
        headerBid.stringValue = app.bundleID
        headerSize.stringValue = "扫描中…"
        emptyStack.isHidden = true
        spinner.isHidden = false
        spinner.startAnimation(nil)

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = findRelated(app: app)
            DispatchQueue.main.async {
                guard let self, self.scanGeneration == gen else { return }
                self.files = result
                self.filesTable.reloadData()
                self.spinner.isHidden = true
                self.spinner.stopAnimation(nil)
                self.checkAllBtn.state = .on
                self.updateHeaderSize()
            }
        }
    }

    func updateHeaderSize() {
        guard let app = selectedApp else { return }
        let n = files.filter(\.checked).count
        let total = files.filter(\.checked).reduce(0) { $0 + $1.size }
        headerSize.stringValue = "已勾选 \(n)/\(files.count) 项 · \(fmtSize(total))"
        statusLabel.stringValue = "「\(app.name)」就绪，共发现 \(files.count) 项关联文件"
    }

    // ---- 应用扫描 ----
    @objc func rescanClicked() { rescan() }

    func rescan() {
        statusLabel.stringValue = "正在扫描应用…"
        spinner.isHidden = false
        spinner.startAnimation(nil)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let list = scanInstalledApps()
            DispatchQueue.main.async {
                guard let self else { return }
                self.apps = list
                self.appsTable.reloadData()
                self.spinner.isHidden = true
                self.spinner.stopAnimation(nil)
                if !list.isEmpty {
                    self.statusLabel.stringValue = "共发现 \(list.count) 个应用"
                    self.appsTable.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
                } else {
                    self.statusLabel.stringValue = "未找到已安装应用"
                }
                self.computeAppSizes()
            }
        }
    }

    /// 后台逐个计算应用占用大小，算完即时刷新对应行
    private var sizeGeneration = 0
    func computeAppSizes() {
        sizeGeneration += 1
        let gen = sizeGeneration
        let fm = FileManager.default
        for i in apps.indices {
            let url = apps[i].url
            DispatchQueue.global(qos: .utility).async { [weak self] in
                let s = dirSize(url)
                DispatchQueue.main.async {
                    guard let self, self.sizeGeneration == gen,
                          fm.fileExists(atPath: url.path) else { return }
                    self.apps[i].size = s
                    self.apps[i].sizeLoaded = true
                    self.appsTable.reloadData(forRowIndexes: IndexSet(integer: i),
                                              columnIndexes: IndexSet(integer: 0))
                }
            }
        }
    }

    // ---- 卸载 ----
    @objc func uninstallClicked() {
        guard let app = selectedApp else {
            alert("请先在左侧选择要卸载的应用")
            return
        }
        if app.bundleID == ownBundleID {
            alert("不能卸载本应用自身")
            return
        }
        let targets = files.filter(\.checked)
        guard !targets.isEmpty else {
            alert("没有勾选任何要删除的项目")
            return
        }
        let total = targets.reduce(0) { $0 + $1.size }
        let confirm = NSAlert()
        confirm.messageText = "确认卸载「\(app.name)」？"
        confirm.informativeText = "将把应用本体及 \(targets.count - 1) 项残留（共 \(fmtSize(total))）移入废纸篓。\n如需恢复，可从废纸篓拖回。"
        confirm.addButton(withTitle: "卸载")
        confirm.addButton(withTitle: "取消")
        confirm.beginSheetModal(for: view.window!) { [weak self] resp in
            guard resp == .alertFirstButtonReturn else { return }
            self?.doUninstall(app: app, targets: targets)
        }
    }

    // ---- 权限辅助 ----
    func isRootNeeded(_ path: String) -> Bool {
        path.hasPrefix("/Applications/") || path.hasPrefix("/Library/") ||
        path.hasPrefix("/private/var/") || path == "/Applications"
    }
    func isTCCNeeded(_ path: String) -> Bool {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return path.hasPrefix(home + "/Library/Containers") ||
               path.hasPrefix(home + "/Library/Group Containers")
    }

    /// 用管理员权限强制删除（弹出系统密码框）
    @discardableResult
    func adminRmRf(_ path: String) -> Bool {
        let q = path.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "'\\''")
        let script = "do shell script \"rm -rf '\(q)'\" with administrator privileges"
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", script]
        do {
            try p.run()
            p.waitUntilExit()
            return p.terminationStatus == 0
        } catch { return false }
    }

    func openFDASettings() {
        if let u = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
            NSWorkspace.shared.open(u)
        }
    }

    func doUninstall(app: AppEntry, targets: [FoundFile]) {
        uninstallBtn.isEnabled = false
        statusLabel.stringValue = "正在卸载…"
        spinner.isHidden = false
        spinner.startAnimation(nil)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            if let running = NSRunningApplication.runningApplications(withBundleIdentifier: app.bundleID).first {
                running.terminate()
                var waited = 0.0
                while !running.isTerminated && waited < 3 { usleep(150000); waited += 0.15 }
                if !running.isTerminated { running.forceTerminate() }
            }
            let fm = FileManager.default
            var ok = 0, fail = 0
            var failMsg = ""
            for t in targets {
                do {
                    try fm.trashItem(at: t.url, resultingItemURL: nil)
                    ok += 1
                } catch {
                    fail += 1
                    failMsg += "\n• \(t.url.path)（\(error.localizedDescription)）"
                }
            }
            DispatchQueue.main.async {
                guard let self else { return }
                self.uninstallBtn.isEnabled = true
                self.spinner.isHidden = true
                self.spinner.stopAnimation(nil)

                // ---- 第二阶段：分类处理失败项 ----
                var rootPaths: [String] = []
                var tccPaths: [String] = []
                for t in targets where fm.fileExists(atPath: t.url.path) {
                    if self.isRootNeeded(t.url.path) { rootPaths.append(t.url.path) }
                    else if self.isTCCNeeded(t.url.path) { tccPaths.append(t.url.path) }
                }
                let trashed = ok
                var adminOk = 0

                func finish(_ extra: String) {
                    self.statusLabel.stringValue = "已卸载「\(app.name)」：\(trashed) 项入废纸篓\(extra)"
                    self.selectedApp = nil
                    self.files = []
                    self.filesTable.reloadData()
                    self.headerIcon.image = NSImage(systemSymbolName: "square.grid.2x2", accessibilityDescription: nil)
                    self.headerName.stringValue = "选择左侧应用"
                    self.headerBid.stringValue = "拖入 .app 也可卸载"
                    self.headerSize.stringValue = ""
                    self.emptyStack.isHidden = false
                    self.rescan()
                }

                if !rootPaths.isEmpty {
                    // 请求管理员密码删除 /Applications 等目录中的残留
                    let a = NSAlert()
                    a.messageText = "需要管理员权限"
                    a.informativeText = "有 \(rootPaths.count) 项位于系统目录（如 /Applications），需要输入管理员密码才能删除：\n" +
                        rootPaths.prefix(5).map { "• \($0)" }.joined(separator: "\n")
                    a.addButton(withTitle: "输入密码删除")
                    a.addButton(withTitle: "跳过")
                    a.beginSheetModal(for: self.view.window!) { resp in
                        if resp == .alertFirstButtonReturn {
                            for p in rootPaths where self.adminRmRf(p) { adminOk += 1 }
                        }
                        if !tccPaths.isEmpty {
                            self.showTCAGuide(app: app, tccPaths: tccPaths, trashed: trashed, adminOk: adminOk, finish: finish)
                        } else {
                            finish(adminOk > 0 ? "，管理员权限删除 \(adminOk) 项" : "")
                        }
                    }
                } else if !tccPaths.isEmpty {
                    self.showTCAGuide(app: app, tccPaths: tccPaths, trashed: trashed, adminOk: 0, finish: finish)
                } else {
                    finish(failMsg.isEmpty ? "" : "，\(fail) 项失败")
                    if !failMsg.isEmpty { self.alert("以下项目删除失败：" + failMsg) }
                }
            }
        }
    }

    /// 引导用户授予「完全磁盘访问权限」以清理 Containers 残留
    func showTCAGuide(app: AppEntry, tccPaths: [String], trashed: Int, adminOk: Int, finish: @escaping (String) -> Void) {
        let a = NSAlert()
        a.messageText = "还差一步：需要「完全磁盘访问权限」"
        a.informativeText = "有 \(tccPaths.count) 项位于系统隐私保护区（Containers），macOS 规定必须授权才能删除：\n\n" +
            "系统设置 → 隐私与安全性 → 完全磁盘访问权限 → 打开本应用开关。\n\n" +
            "授权后重新选择「\(app.name)」再点一次卸载即可清零。"
        a.addButton(withTitle: "打开系统设置")
        a.addButton(withTitle: "稍后再说")
        a.beginSheetModal(for: view.window!) { resp in
            if resp == .alertFirstButtonReturn { self.openFDASettings() }
            var extra = ""
            if adminOk > 0 { extra += "，管理员权限删除 \(adminOk) 项" }
            if !tccPaths.isEmpty { extra += "，\(tccPaths.count) 项待授权后清理" }
            finish(extra)
        }
    }

    func alert(_ text: String) {
        let a = NSAlert()
        a.messageText = text
        a.runModal()
    }

    func acceptDroppedApp(_ url: URL) {
        let name = url.deletingPathExtension().lastPathComponent
        let bundle = Bundle(url: url)
        let app = AppEntry(url: url,
                           name: name,
                           bundleID: bundle?.bundleIdentifier ?? "unknown.\(name)",
                           execName: bundle?.executablePath.map { URL(fileURLWithPath: $0).lastPathComponent } ?? name)
        appsTable.deselectAll(nil)
        selectApp(app)
    }
}

// MARK: - 应用入口
final class AppDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow?
    func applicationDidFinishLaunching(_ note: Notification) {
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 620),
                           styleMask: [.titled, .closable, .miniaturizable, .resizable],
                           backing: .buffered, defer: false)
        win.title = "Mac 干净卸载器"
        win.center()
        let vc = MainVC()
        win.contentViewController = vc
        win.makeKeyAndOrderFront(nil)
        win.isReleasedWhenClosed = false
        // macOS 14+ 上 activate 需在窗口 orderFront 之后调用才能可靠置前
        NSApp.activate(ignoringOtherApps: true)
        window = win
    }

    /// 用户关闭窗口后再次点击 Dock/启动台图标时，重新显示窗口
    /// （否则 App 常驻后台，点击图标无任何反应，表现为「软件看不见了」）
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            NSApp.activate(ignoringOtherApps: true)
            window?.makeKeyAndOrderFront(nil)
        }
        return true
    }

    /// App 被点击激活时，若窗口已存在则确保置前
    func applicationDidBecomeActive(_ notification: Notification) {
        if window?.isVisible == true {
            window?.makeKeyAndOrderFront(nil)
        }
    }
}

#if UNINSTALL_TEST  // 测试模式：与 GUI 完全相同的扫描/删除代码路径
let args = CommandLine.arguments
let doTrash = args.contains("--trash")
guard let appPath = args.first(where: { $0.hasSuffix(".app") && FileManager.default.fileExists(atPath: $0) }) else {
    print("用法: test <App路径> [--trash]")
    exit(1)
}
let url = URL(fileURLWithPath: appPath)
let bundle = Bundle(url: url)
let testApp = AppEntry(url: url,
                       name: url.deletingPathExtension().lastPathComponent,
                       bundleID: bundle?.bundleIdentifier ?? "unknown",
                       execName: bundle?.executablePath.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "unknown")
let found = findRelated(app: testApp)
print("共找到 \(found.count) 项：")
for f in found { print("  \(f.isAppBundle ? "[本体]" : "[残留]") \(f.url.path)  \(fmtSize(f.size))") }
if doTrash {
    let fm = FileManager.default
    var ok = 0, fail = 0
    for f in found {
        do { try fm.trashItem(at: f.url, resultingItemURL: nil); ok += 1 }
        catch { fail += 1; print("  删除失败: \(f.url.path)  \(error.localizedDescription)") }
    }
    print("移入废纸篓 \(ok) 项，失败 \(fail) 项")
}
exit(0)
#else
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
#endif
