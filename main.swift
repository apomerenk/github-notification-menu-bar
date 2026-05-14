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
    private var seenIDs = Set<String>()
    private var hasFetchedOnce = false
    private var pollIntervalSeconds: TimeInterval = 60
    private var launchAtLoginItem: NSMenuItem!

    // Dynamically inserted notification rows at the top of the menu carry this tag
    // so we can remove the previous batch before inserting the next.
    private static let notificationItemTag = 9001

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        renderBadge(state: .idle)

        let menu = NSMenu()
        menu.delegate = self
        menu.addItem(withTitle: "Open GitHub Notifications", action: #selector(openNotifications), keyEquivalent: "o")
        menu.addItem(withTitle: "Refresh Now", action: #selector(refresh), keyEquivalent: "r")
        menu.addItem(NSMenuItem.separator())
        menu.addItem(withTitle: "Set Token…", action: #selector(setToken), keyEquivalent: ",")
        launchAtLoginItem = NSMenuItem(title: "Launch at Login", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        menu.addItem(launchAtLoginItem)
        menu.addItem(NSMenuItem.separator())
        menu.addItem(withTitle: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        statusItem.menu = menu

        UNUserNotificationCenter.current().delegate = self
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }

        loadToken()
        if token == nil || token?.isEmpty == true {
            DispatchQueue.main.async { self.setToken() }
        }
        startPolling()
    }

    // MARK: Token storage

    private func tokenURL() -> URL {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/gh-notif-bar", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("token")
    }

    private func loadToken() {
        if let s = try? String(contentsOf: tokenURL(), encoding: .utf8) {
            token = s.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    @objc private func setToken() {
        let alert = NSAlert()
        alert.messageText = "GitHub Personal Access Token"
        alert.informativeText = """
        Needs a classic PAT with the 'notifications' scope, or a fine-grained PAT with 'Notifications: read'.

        Click 'Create Token…' to open GitHub's classic-token page with the 'notifications' scope pre-selected — just hit Generate and paste the result here. For a fine-grained token, open github.com/settings/personal-access-tokens/new and enable 'Notifications: read' under Account permissions.

        Stored at ~/.config/gh-notif-bar/token (0600).
        """
        let field = PasteableSecureTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        field.stringValue = token ?? ""
        alert.accessoryView = field
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Create Token…")
        NSApp.activate(ignoringOtherApps: true)
        alert.window.initialFirstResponder = field

        switch alert.runModal() {
        case .alertFirstButtonReturn:
            let value = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            do {
                try value.write(to: tokenURL(), atomically: true, encoding: .utf8)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tokenURL().path)
                token = value
                seenIDs.removeAll()
                hasFetchedOnce = false
                refresh()
            } catch {
                NSLog("Failed to save token: \(error)")
            }
        case .alertThirdButtonReturn:
            let createURL = URL(string: "https://github.com/settings/tokens/new?scopes=notifications&description=GitHub%20Notifications%20menu%20bar")!
            NSWorkspace.shared.open(createURL)
            DispatchQueue.main.async { self.setToken() }
        default:
            break
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
            NSLog("Launch-at-login toggle failed: \(error)")
        }
    }

    func menuWillOpen(_ menu: NSMenu) {
        launchAtLoginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
    }

    private func startPolling() {
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: pollIntervalSeconds, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    @objc private func refresh() {
        guard let token, !token.isEmpty else {
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
                NSLog("Fetch error: \(err)")
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
                NSLog("Bad response: status=\(http.statusCode)")
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

        renderBadge(state: .count(unread.count))
        updateNotificationItems(unread: unread, read: read)

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

    // MARK: Notification list in menu

    private func updateNotificationItems(unread: [[String: Any]], read: [[String: Any]]) {
        guard let menu = statusItem.menu else { return }

        while let first = menu.items.first, first.tag == Self.notificationItemTag {
            menu.removeItem(first)
        }

        let unreadRows = Array(unread.prefix(15))
        let readRows = Array(read.prefix(10))
        guard !unreadRows.isEmpty || !readRows.isEmpty else { return }

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

        for n in unreadRows.reversed() {
            let item = makeNotificationItem(n)
            item.tag = Self.notificationItemTag
            menu.insertItem(item, at: 0)
        }
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
