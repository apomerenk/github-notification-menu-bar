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
    private var token: String?
    private var prFetchEnabled: Bool = false
    private var seenIDs = Set<String>()
    private var hasFetchedOnce = false
    private var pollIntervalSeconds: TimeInterval = 60
    private var launchAtLoginItem: NSMenuItem!

    private var latestUnread: [[String: Any]] = []
    private var latestRead: [[String: Any]] = []
    private var latestPRs: [[String: Any]] = []
    private var latestAuthored: [[String: Any]] = []

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
        menu.addItem(withTitle: "Set Token…", action: #selector(setTokens), keyEquivalent: ",")
        launchAtLoginItem = NSMenuItem(title: "Launch at Login", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        menu.addItem(launchAtLoginItem)
        menu.addItem(NSMenuItem.separator())
        menu.addItem(withTitle: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        statusItem.menu = menu

        UNUserNotificationCenter.current().delegate = self
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }

        loadTokens()
        if (token ?? "").isEmpty {
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

    private func tokenURL() -> URL { configDir().appendingPathComponent("token") }
    private static let prFetchEnabledKey = "prFetchEnabled"

    private func loadTokens() {
        let fm = FileManager.default

        // Migrate from the short-lived two-file layout (notifications_token + pr_token):
        // copy notifications_token into 'token' if it's the only one present, infer
        // prFetchEnabled from the existence of a non-empty pr_token, then clean up.
        let notifLegacy = configDir().appendingPathComponent("notifications_token")
        let prLegacy = configDir().appendingPathComponent("pr_token")
        if fm.fileExists(atPath: notifLegacy.path) && !fm.fileExists(atPath: tokenURL().path) {
            try? fm.moveItem(at: notifLegacy, to: tokenURL())
        }
        if let s = try? String(contentsOf: prLegacy, encoding: .utf8),
           !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            UserDefaults.standard.set(true, forKey: Self.prFetchEnabledKey)
        }
        try? fm.removeItem(at: prLegacy)
        try? fm.removeItem(at: notifLegacy)

        if let s = try? String(contentsOf: tokenURL(), encoding: .utf8) {
            token = s.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        prFetchEnabled = UserDefaults.standard.bool(forKey: Self.prFetchEnabledKey)
    }

    private func writeToken(_ value: String, to url: URL) throws {
        try value.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    @objc private func openCreateTokenURL() {
        // Pre-tick both scopes the app might need. If the user only wants notifications
        // they can untick 'repo' on the GitHub page before generating.
        let url = URL(string: "https://github.com/settings/tokens/new?scopes=notifications,repo&description=GitHub%20Notifications%20menu%20bar")!
        NSWorkspace.shared.open(url)
    }

    @objc private func setTokens() {
        let alert = NSAlert()
        alert.messageText = "GitHub Token"
        alert.informativeText = """
        One classic personal access token. The 'notifications' scope is required (powers the menu's unread/read rows and banner alerts). The 'repo' scope is optional — tick it on GitHub to also enable the 'Needs your review' PR section.

        Click Create… to open GitHub's token page with both scopes pre-ticked. After generating, paste the token below. If you generated it with 'repo' scope, also tick the checkbox so the app fetches PRs.

        For SSO orgs, click 'Configure SSO' next to the token on github.com/settings/tokens after generating, to authorize for the org. Stored at ~/.config/gh-notif-bar/token (mode 0600).
        """

        let containerWidth: CGFloat = 460
        let container = NSView(frame: NSRect(x: 0, y: 0, width: containerWidth, height: 80))

        let field = PasteableSecureTextField(frame: NSRect(x: 0, y: 52, width: 340, height: 24))
        field.stringValue = token ?? ""
        container.addSubview(field)

        let createBtn = NSButton(title: "Create…", target: self, action: #selector(openCreateTokenURL))
        createBtn.frame = NSRect(x: 352, y: 50, width: 100, height: 28)
        createBtn.bezelStyle = .rounded
        container.addSubview(createBtn)

        let repoCheckbox = NSButton(checkboxWithTitle: "Token has 'repo' scope (enable Needs your review section)", target: nil, action: nil)
        repoCheckbox.state = prFetchEnabled ? .on : .off
        repoCheckbox.frame = NSRect(x: 0, y: 14, width: containerWidth, height: 18)
        container.addSubview(repoCheckbox)

        alert.accessoryView = container
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        alert.window.initialFirstResponder = field

        if alert.runModal() == .alertFirstButtonReturn {
            let value = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)

            do {
                try writeToken(value, to: tokenURL())
                token = value
            } catch {
                self.log("Failed to save token: \(error)")
            }

            prFetchEnabled = (repoCheckbox.state == .on)
            UserDefaults.standard.set(prFetchEnabled, forKey: Self.prFetchEnabledKey)

            seenIDs.removeAll()
            hasFetchedOnce = false
            latestPRs = []
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
        refreshAuthoredPRs()
    }

    @objc private func refresh() {
        guard let token = token, !token.isEmpty else {
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
            let unreadCount = arr.filter { ($0["unread"] as? Bool) ?? true }.count
            let readCount = arr.count - unreadCount
            self.log("Notifications fetch: status=\(http.statusCode), total=\(arr.count) (unread=\(unreadCount), read=\(readCount))")
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
        updateBadge()
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
        searchPRs(query: "is:pr is:open review-requested:@me", label: "review-requested") { [weak self] items in
            guard let self else { return }
            self.latestPRs = items
            self.updateBadge()
            self.rebuildMenu()
        }
    }

    @objc private func refreshAuthoredPRs() {
        searchPRs(query: "is:pr is:open author:@me", label: "authored") { [weak self] items in
            guard let self else { return }
            self.latestAuthored = items
            self.rebuildMenu()
        }
    }

    private func searchPRs(query: String, label: String, completion: @escaping ([[String: Any]]) -> Void) {
        guard prFetchEnabled, let token = token, !token.isEmpty else {
            DispatchQueue.main.async { completion([]) }
            return
        }
        guard let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "https://api.github.com/search/issues?q=\(encoded)&per_page=30") else {
            return
        }

        var req = URLRequest(url: url)
        req.cachePolicy = .reloadIgnoringLocalCacheData
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        req.setValue("gh-notif-bar", forHTTPHeaderField: "User-Agent")

        URLSession.shared.dataTask(with: req) { [weak self] data, resp, err in
            guard let self else { return }
            if let err = err {
                self.log("PR fetch (\(label)) error: \(err.localizedDescription)")
                return
            }
            guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode),
                  let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let items = json["items"] as? [[String: Any]] else {
                let status = (resp as? HTTPURLResponse)?.statusCode ?? -1
                let snippet = (data.flatMap { String(data: $0, encoding: .utf8) }?.prefix(200)).map(String.init) ?? ""
                self.log("PR bad response (\(label)): status=\(status) body=\(snippet)")
                return
            }
            let totalCount = (json["total_count"] as? Int) ?? items.count
            self.log("PR fetch (\(label)): status=\(http.statusCode), items=\(items.count), total_count=\(totalCount)")
            DispatchQueue.main.async { completion(items) }
        }.resume()
    }

    private func updateBadge() {
        let total = latestUnread.count + latestPRs.count
        renderBadge(state: .count(total))
    }

    // MARK: Menu rebuild

    private func rebuildMenu() {
        guard let menu = statusItem.menu else { return }

        while let first = menu.items.first, first.tag == Self.notificationItemTag {
            menu.removeItem(first)
        }

        let unreadRows = Array(latestUnread.prefix(15))
        let readRows = Array(latestRead.prefix(10))
        let reviewRows = Array(latestPRs.prefix(15))
        let authoredRows = Array(latestAuthored.prefix(15))
        guard !unreadRows.isEmpty || !readRows.isEmpty || !reviewRows.isEmpty || !authoredRows.isEmpty else { return }

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

        // Authored PRs section (below review-requested in final order, so insert first).
        insertPRSection(authoredRows, readyHeader: "Your PRs", draftsHeader: "Your drafts", into: menu)

        // Review-requested PRs section.
        insertPRSection(reviewRows, readyHeader: "Needs your review", draftsHeader: "Drafts", into: menu)

        for n in unreadRows.reversed() {
            let item = makeNotificationItem(n)
            item.tag = Self.notificationItemTag
            menu.insertItem(item, at: 0)
        }
    }

    private func insertPRSection(_ rows: [[String: Any]], readyHeader: String, draftsHeader: String, into menu: NSMenu) {
        guard !rows.isEmpty else { return }
        let drafts = rows.filter { ($0["draft"] as? Bool) == true }
        let ready = rows.filter { ($0["draft"] as? Bool) != true }

        if !drafts.isEmpty {
            for item in drafts.reversed() {
                let menuItem = makePRItem(item)
                menuItem.tag = Self.notificationItemTag
                menu.insertItem(menuItem, at: 0)
            }
            let h = NSMenuItem(title: draftsHeader, action: nil, keyEquivalent: "")
            h.isEnabled = false
            h.tag = Self.notificationItemTag
            menu.insertItem(h, at: 0)
        }

        if !ready.isEmpty {
            for item in ready.reversed() {
                let menuItem = makePRItem(item)
                menuItem.tag = Self.notificationItemTag
                menu.insertItem(menuItem, at: 0)
            }
        }

        let topHeader = NSMenuItem(title: ready.isEmpty ? "\(readyHeader) (drafts)" : readyHeader, action: nil, keyEquivalent: "")
        topHeader.isEnabled = false
        topHeader.tag = Self.notificationItemTag
        menu.insertItem(topHeader, at: 0)
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

        var header = "=== gh-notif-bar diagnostic — \(nowStamp) ===\n"
        header += "token:           \(tokenMask(token))\n"
        header += "pr fetch:        \(prFetchEnabled ? "enabled" : "disabled")\n"
        header += "poll interval:   \(Int(pollIntervalSeconds))s\n"
        header += "latest unread:   \(latestUnread.count)\n"
        header += "latest read:     \(latestRead.count)\n"
        header += "latest review-requested PRs: \(latestPRs.count)\n"
        header += "latest authored PRs:         \(latestAuthored.count)\n"
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
