import AppKit
import ServiceManagement
import UserNotifications

// MARK: - Entry point

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate
app.run()

// MARK: - Paste-friendly secure field
//
// NSSecureTextField inside an NSAlert accessoryView doesn't receive Cmd+V/C/X/A
// because the alert window doesn't route key equivalents to the field. Forward
// them to the standard responder chain ourselves.

final class PasteableSecureTextField: NSSecureTextField {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command {
            switch event.charactersIgnoringModifiers {
            case "v": if NSApp.sendAction(#selector(NSText.paste(_:)), to: nil, from: self) { return true }
            case "c": if NSApp.sendAction(#selector(NSText.copy(_:)), to: nil, from: self) { return true }
            case "x": if NSApp.sendAction(#selector(NSText.cut(_:)), to: nil, from: self) { return true }
            case "a": if NSApp.sendAction(#selector(NSResponder.selectAll(_:)), to: nil, from: self) { return true }
            case "z": if NSApp.sendAction(Selector(("undo:")), to: nil, from: self) { return true }
            default: break
            }
        }
        return super.performKeyEquivalent(with: event)
    }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, UNUserNotificationCenterDelegate {
    private var statusItem: NSStatusItem!
    private var timer: Timer?
    private var notificationsToken: String?
    private var prToken: String?
    private var seenIDs = Set<String>()
    private var hasFetchedOnce = false
    private var pollIntervalSeconds: TimeInterval = 60
    private var launchAtLoginItem: NSMenuItem!

    private var latestUnread: [[String: Any]] = []
    private var latestRead: [[String: Any]] = []
    private var latestPRs: [[String: Any]] = []

    private var logEntries: [(Date, String)] = []
    private static let logEntriesLimit = 500
    private var logWindow: NSWindow?
    private var logTextView: NSTextView?

    // Dynamically inserted notification rows at the top of the menu carry this tag
    // so we can remove the previous batch before inserting the next.
    private static let notificationItemTag = 9001

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        renderBadge(state: .idle)

        let menu = NSMenu()
        menu.delegate = self
        menu.addItem(withTitle: "Open GitHub Notifications", action: #selector(openNotifications), keyEquivalent: "o")
        menu.addItem(withTitle: "Refresh Now", action: #selector(refreshAll), keyEquivalent: "r")
        menu.addItem(withTitle: "Show Logs…", action: #selector(showLogs), keyEquivalent: "l")
        menu.addItem(NSMenuItem.separator())
        menu.addItem(withTitle: "Set Tokens…", action: #selector(setTokens), keyEquivalent: ",")
        launchAtLoginItem = NSMenuItem(title: "Launch at Login", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        menu.addItem(launchAtLoginItem)
        menu.addItem(NSMenuItem.separator())
        menu.addItem(withTitle: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        statusItem.menu = menu

        UNUserNotificationCenter.current().delegate = self
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }

        loadTokens()
        if (notificationsToken ?? "").isEmpty && (prToken ?? "").isEmpty {
            DispatchQueue.main.async { self.setTokens() }
        }
        startPolling()
    }

    // MARK: Token storage

    private func configDir() -> URL {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/gh-notif-bar", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func notificationsTokenURL() -> URL { configDir().appendingPathComponent("notifications_token") }
    private func prTokenURL() -> URL { configDir().appendingPathComponent("pr_token") }
    private func legacyTokenURL() -> URL { configDir().appendingPathComponent("token") }

    private func loadTokens() {
        let legacy = legacyTokenURL()
        let notif = notificationsTokenURL()
        let fm = FileManager.default
        if fm.fileExists(atPath: legacy.path) && !fm.fileExists(atPath: notif.path) {
            try? fm.moveItem(at: legacy, to: notif)
        }
        if let s = try? String(contentsOf: notif, encoding: .utf8) {
            notificationsToken = s.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let s = try? String(contentsOf: prTokenURL(), encoding: .utf8) {
            prToken = s.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    private func writeToken(_ value: String, to url: URL) throws {
        try value.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    @objc private func openCreateNotificationsTokenURL() {
        let url = URL(string: "https://github.com/settings/tokens/new?scopes=notifications&description=GitHub%20Notifications%20menu%20bar")!
        NSWorkspace.shared.open(url)
    }

    @objc private func openCreatePRTokenURL() {
        // Fine-grained PATs are created from the same root page; no URL params pre-select permissions.
        let url = URL(string: "https://github.com/settings/personal-access-tokens/new")!
        NSWorkspace.shared.open(url)
    }

    @objc private func setTokens() {
        let alert = NSAlert()
        alert.messageText = "GitHub Tokens"
        alert.informativeText = """
        Two separate tokens, each scoped to one endpoint:

        • Notifications — classic PAT with 'notifications' scope.
        • Pull requests — fine-grained PAT with 'Pull requests: read' on the relevant repos (plus 'Metadata: read').

        Use the Create… buttons to open the right token page. Tokens are stored at ~/.config/gh-notif-bar/ (mode 0600).
        """

        let containerWidth: CGFloat = 440
        let container = NSView(frame: NSRect(x: 0, y: 0, width: containerWidth, height: 120))

        let notifLabel = NSTextField(labelWithString: "Notifications (classic):")
        notifLabel.frame = NSRect(x: 0, y: 96, width: containerWidth, height: 16)
        container.addSubview(notifLabel)

        let notifField = PasteableSecureTextField(frame: NSRect(x: 0, y: 64, width: 320, height: 24))
        notifField.stringValue = notificationsToken ?? ""
        container.addSubview(notifField)

        let notifBtn = NSButton(title: "Create…", target: self, action: #selector(openCreateNotificationsTokenURL))
        notifBtn.frame = NSRect(x: 332, y: 62, width: 100, height: 28)
        notifBtn.bezelStyle = .rounded
        container.addSubview(notifBtn)

        let prLabel = NSTextField(labelWithString: "Pull requests (fine-grained):")
        prLabel.frame = NSRect(x: 0, y: 32, width: containerWidth, height: 16)
        container.addSubview(prLabel)

        let prField = PasteableSecureTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        prField.stringValue = prToken ?? ""
        container.addSubview(prField)

        let prBtn = NSButton(title: "Create…", target: self, action: #selector(openCreatePRTokenURL))
        prBtn.frame = NSRect(x: 332, y: -2, width: 100, height: 28)
        prBtn.bezelStyle = .rounded
        container.addSubview(prBtn)

        alert.accessoryView = container
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        alert.window.initialFirstResponder = notifField

        if alert.runModal() == .alertFirstButtonReturn {
            let notifValue = notifField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            let prValue = prField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)

            do {
                try writeToken(notifValue, to: notificationsTokenURL())
                notificationsToken = notifValue
            } catch {
                self.log("Failed to save notifications token: \(error)")
            }
            do {
                try writeToken(prValue, to: prTokenURL())
                prToken = prValue
            } catch {
                self.log("Failed to save PR token: \(error)")
            }
            seenIDs.removeAll()
            hasFetchedOnce = false
            refreshAll()
        }
    }

    // MARK: Actions

    @objc private func openNotifications() {
        NSWorkspace.shared.open(URL(string: "https://github.com/notifications")!)
    }

    // MARK: Launch at Login

    @objc private func toggleLaunchAtLogin() {
        let svc = SMAppService.mainApp
        do {
            if svc.status == .enabled {
                try svc.unregister()
            } else {
                try svc.register()
            }
        } catch {
            log("Launch-at-login toggle failed: \(error)")
        }
    }

    func menuWillOpen(_ menu: NSMenu) {
        launchAtLoginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
    }

    private func startPolling() {
        refreshAll()
        timer = Timer.scheduledTimer(withTimeInterval: pollIntervalSeconds, repeats: true) { [weak self] _ in
            self?.refreshAll()
        }
    }

    @objc private func refreshAll() {
        refresh()
        refreshPRs()
    }

    @objc private func refresh() {
        guard let token = notificationsToken, !token.isEmpty else {
            renderBadge(state: .needsToken)
            return
        }
        var req = URLRequest(url: URL(string: "https://api.github.com/notifications?all=true")!)
        req.cachePolicy = .reloadIgnoringLocalCacheData
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        req.setValue("gh-notif-bar", forHTTPHeaderField: "User-Agent")

        URLSession.shared.dataTask(with: req) { [weak self] data, resp, err in
            guard let self else { return }
            if let err = err {
                self.log("Notifications fetch error: \(err.localizedDescription)")
                DispatchQueue.main.async { self.renderBadge(state: .error) }
                return
            }
            guard let http = resp as? HTTPURLResponse else { return }

            // Respect GitHub's poll interval header when present.
            if let pollHeader = http.value(forHTTPHeaderField: "X-Poll-Interval"),
               let secs = TimeInterval(pollHeader), secs > 0 {
                DispatchQueue.main.async { self.adjustPollInterval(to: max(secs, 60)) }
            }

            guard (200..<300).contains(http.statusCode), let data = data,
                  let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
                self.log("Notifications bad response: status=\(http.statusCode)")
                DispatchQueue.main.async {
                    self.renderBadge(state: http.statusCode == 401 ? .needsToken : .error)
                }
                return
            }
            DispatchQueue.main.async { self.handle(notifications: arr) }
        }.resume()
    }

    private func adjustPollInterval(to secs: TimeInterval) {
        guard secs != pollIntervalSeconds else { return }
        pollIntervalSeconds = secs
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: secs, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    private func handle(notifications: [[String: Any]]) {
        let unread = notifications.filter { ($0["unread"] as? Bool) ?? true }
        let read = notifications.filter { ($0["unread"] as? Bool) == false }

        latestUnread = unread
        latestRead = read
        renderBadge(state: .count(unread.count))
        rebuildMenu()

        let currentIDs = Set(unread.compactMap { $0["id"] as? String })
        if hasFetchedOnce {
            for n in unread {
                guard let id = n["id"] as? String, !seenIDs.contains(id) else { continue }
                let subject = n["subject"] as? [String: Any]
                let title = (subject?["title"] as? String) ?? "New notification"
                let repoName = (n["repository"] as? [String: Any])?["full_name"] as? String ?? "GitHub"
                let type = (subject?["type"] as? String) ?? ""
                let body = type.isEmpty ? title : "\(type): \(title)"
                post(title: repoName, body: body, id: id)
            }
        }
        seenIDs = currentIDs
        hasFetchedOnce = true
    }

    // MARK: PR fetching

    @objc private func refreshPRs() {
        guard let token = prToken, !token.isEmpty else {
            latestPRs = []
            rebuildMenu()
            return
        }
        var req = URLRequest(url: URL(string: "https://api.github.com/search/issues?q=is:pr+is:open+review-requested:@me&per_page=20")!)
        req.cachePolicy = .reloadIgnoringLocalCacheData
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        req.setValue("gh-notif-bar", forHTTPHeaderField: "User-Agent")

        URLSession.shared.dataTask(with: req) { [weak self] data, resp, err in
            guard let self else { return }
            if let err = err {
                self.log("PR fetch error: \(err.localizedDescription)")
                return
            }
            guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode),
                  let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let items = json["items"] as? [[String: Any]] else {
                let status = (resp as? HTTPURLResponse)?.statusCode ?? -1
                let snippet = (data.flatMap { String(data: $0, encoding: .utf8) }?.prefix(200)).map(String.init) ?? ""
                self.log("PR bad response: status=\(status) body=\(snippet)")
                return
            }
            DispatchQueue.main.async {
                self.latestPRs = items
                self.rebuildMenu()
            }
        }.resume()
    }

    // MARK: Menu rebuild

    private func rebuildMenu() {
        guard let menu = statusItem.menu else { return }

        while let first = menu.items.first, first.tag == Self.notificationItemTag {
            menu.removeItem(first)
        }

        let unreadRows = Array(latestUnread.prefix(15))
        let readRows = Array(latestRead.prefix(10))
        let prRows = Array(latestPRs.prefix(15))
        guard !unreadRows.isEmpty || !readRows.isEmpty || !prRows.isEmpty else { return }

        // Inserting at position 0 in reverse of intended final order.
        let separator = NSMenuItem.separator()
        separator.tag = Self.notificationItemTag
        menu.insertItem(separator, at: 0)

        if !readRows.isEmpty {
            let submenu = NSMenu(title: "Recently Read")
            for n in readRows {
                submenu.addItem(makeNotificationItem(n))
            }
            let parent = NSMenuItem(title: "Recently Read", action: nil, keyEquivalent: "")
            parent.submenu = submenu
            parent.tag = Self.notificationItemTag
            menu.insertItem(parent, at: 0)
        }

        if !prRows.isEmpty {
            for item in prRows.reversed() {
                let menuItem = makePRItem(item)
                menuItem.tag = Self.notificationItemTag
                menu.insertItem(menuItem, at: 0)
            }
            let header = NSMenuItem(title: "Needs your review", action: nil, keyEquivalent: "")
            header.isEnabled = false
            header.tag = Self.notificationItemTag
            menu.insertItem(header, at: 0)
        }

        for n in unreadRows.reversed() {
            let item = makeNotificationItem(n)
            item.tag = Self.notificationItemTag
            menu.insertItem(item, at: 0)
        }
    }

    private func makePRItem(_ item: [String: Any]) -> NSMenuItem {
        let title = item["title"] as? String ?? "PR"
        let number = item["number"] as? Int ?? 0
        let htmlURLString = item["html_url"] as? String ?? "https://github.com/pulls"
        let repo = prRepoSlug(fromHTMLURL: htmlURLString)

        let combined = repo.isEmpty ? "\(title) #\(number)" : "\(repo)#\(number) — \(title)"
        let truncated = combined.count > 70 ? String(combined.prefix(67)) + "…" : combined

        let menuItem = NSMenuItem(title: truncated, action: #selector(openNotificationItem(_:)), keyEquivalent: "")
        menuItem.target = self
        menuItem.image = symbolImage(forSubjectType: "PullRequest")
        menuItem.representedObject = htmlURLString
        return menuItem
    }

    private func prRepoSlug(fromHTMLURL urlString: String) -> String {
        guard let u = URL(string: urlString), u.pathComponents.count >= 3 else { return "" }
        return "\(u.pathComponents[1])/\(u.pathComponents[2])"
    }

    private func makeNotificationItem(_ n: [String: Any]) -> NSMenuItem {
        let subject = n["subject"] as? [String: Any] ?? [:]
        let type = subject["type"] as? String ?? ""
        let title = subject["title"] as? String ?? "Notification"
        let repo = (n["repository"] as? [String: Any])?["full_name"] as? String ?? ""

        let combined = repo.isEmpty ? title : "\(repo) — \(title)"
        let truncated = combined.count > 70 ? String(combined.prefix(67)) + "…" : combined

        let item = NSMenuItem(title: truncated, action: #selector(openNotificationItem(_:)), keyEquivalent: "")
        item.target = self
        item.image = symbolImage(forSubjectType: type)
        item.representedObject = htmlURL(fromSubject: subject).absoluteString
        return item
    }

    @objc private func openNotificationItem(_ sender: NSMenuItem) {
        guard let s = sender.representedObject as? String, let url = URL(string: s) else { return }
        NSWorkspace.shared.open(url)
    }

    private func symbolImage(forSubjectType type: String) -> NSImage? {
        let name: String
        switch type {
        case "PullRequest": name = "arrow.triangle.pull"
        case "Issue":       name = "smallcircle.filled.circle"
        case "Commit":      name = "doc.text"
        case "Release":     name = "tag"
        case "Discussion":  name = "bubble.left"
        case "CheckSuite":  name = "checkmark.seal"
        default:            name = "circle"
        }
        let img = NSImage(systemSymbolName: name, accessibilityDescription: type)
        img?.isTemplate = true
        return img
    }

    private func htmlURL(fromSubject subject: [String: Any]) -> URL {
        let fallback = URL(string: "https://github.com/notifications")!
        guard let apiURL = subject["url"] as? String else { return fallback }
        var s = apiURL.replacingOccurrences(of: "https://api.github.com/repos/", with: "https://github.com/")
        s = s.replacingOccurrences(of: "/pulls/", with: "/pull/")
        s = s.replacingOccurrences(of: "/commits/", with: "/commit/")
        return URL(string: s) ?? fallback
    }

    // MARK: Logs

    private func log(_ message: String) {
        NSLog("%@", message)
        let entry = (Date(), message)
        DispatchQueue.main.async {
            self.logEntries.append(entry)
            if self.logEntries.count > Self.logEntriesLimit {
                self.logEntries.removeFirst(self.logEntries.count - Self.logEntriesLimit)
            }
            if self.logWindow?.isVisible == true {
                self.refreshLogView()
            }
        }
    }

    @objc private func showLogs() {
        if logWindow == nil {
            let win = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 760, height: 460),
                styleMask: [.titled, .closable, .resizable, .miniaturizable],
                backing: .buffered, defer: false
            )
            win.title = "GitHubNotifications — Logs"
            win.isReleasedWhenClosed = false
            win.center()

            let contentView = win.contentView!
            let scrollView = NSScrollView(frame: contentView.bounds)
            scrollView.hasVerticalScroller = true
            scrollView.hasHorizontalScroller = false
            scrollView.autohidesScrollers = false
            scrollView.autoresizingMask = [.width, .height]
            scrollView.borderType = .noBorder

            let textView = NSTextView(frame: scrollView.bounds)
            textView.isEditable = false
            textView.isSelectable = true
            textView.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
            textView.autoresizingMask = .width
            textView.minSize = NSSize(width: 0, height: 0)
            textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
            textView.isVerticallyResizable = true
            textView.isHorizontallyResizable = false
            textView.textContainer?.widthTracksTextView = true
            textView.textContainerInset = NSSize(width: 8, height: 8)

            scrollView.documentView = textView
            contentView.addSubview(scrollView)

            logTextView = textView
            logWindow = win
        }

        refreshLogView()
        NSApp.activate(ignoringOtherApps: true)
        logWindow?.makeKeyAndOrderFront(nil)
    }

    private func refreshLogView() {
        guard let textView = logTextView else { return }

        let fmt = DateFormatter()
        fmt.dateFormat = "HH:mm:ss"
        let nowStamp = fmt.string(from: Date())

        let notifMask = tokenMask(notificationsToken)
        let prMask = tokenMask(prToken)

        var header = "=== gh-notif-bar diagnostic — \(nowStamp) ===\n"
        header += "notifications token: \(notifMask)\n"
        header += "pr token:            \(prMask)\n"
        header += "poll interval:       \(Int(pollIntervalSeconds))s\n"
        header += "latest unread:       \(latestUnread.count)\n"
        header += "latest read:         \(latestRead.count)\n"
        header += "latest PRs:          \(latestPRs.count)\n"
        header += "\n=== Recent log entries (most recent last, max \(Self.logEntriesLimit)) ===\n"

        let body = logEntries.map { (date, msg) in
            "\(fmt.string(from: date))  \(msg)"
        }.joined(separator: "\n")

        textView.string = header + (body.isEmpty ? "(no entries yet)" : body)
        textView.scrollToEndOfDocument(nil)
    }

    private func tokenMask(_ token: String?) -> String {
        guard let t = token, !t.isEmpty else { return "missing" }
        let last = t.suffix(4)
        return "present (\(t.count) chars, ...\(last))"
    }

    // MARK: Badge

    private enum BadgeState {
        case idle
        case count(Int)
        case error
        case needsToken
    }

    private func renderBadge(state: BadgeState) {
        guard let button = statusItem.button else { return }
        let icon = NSImage(systemSymbolName: "tray.fill", accessibilityDescription: "GitHub Notifications")
        icon?.isTemplate = true
        button.image = icon
        button.imagePosition = .imageLeading
        statusItem.isVisible = true
        switch state {
        case .idle:
            button.title = ""
        case .count(let n):
            button.title = n == 0 ? "" : " \(n)"
        case .error:
            button.title = " !"
        case .needsToken:
            button.title = " ?"
        }
    }

    // MARK: Notifications

    private func post(title: String, body: String, id: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let req = UNNotificationRequest(identifier: id, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(req)
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        openNotifications()
        completionHandler()
    }
}
