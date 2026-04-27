import AppKit
import UserNotifications

// MARK: - Entry point

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate
app.run()

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    private var statusItem: NSStatusItem!
    private var timer: Timer?
    private var token: String?
    private var seenIDs = Set<String>()
    private var hasFetchedOnce = false
    private var pollIntervalSeconds: TimeInterval = 60

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        renderBadge(state: .idle)

        let menu = NSMenu()
        menu.addItem(withTitle: "Open GitHub Notifications", action: #selector(openNotifications), keyEquivalent: "o")
        menu.addItem(withTitle: "Refresh Now", action: #selector(refresh), keyEquivalent: "r")
        menu.addItem(NSMenuItem.separator())
        menu.addItem(withTitle: "Set Token…", action: #selector(setToken), keyEquivalent: ",")
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
        alert.informativeText = "Create one at github.com/settings/tokens with the 'notifications' scope (or a fine-grained token with Notifications: read).\n\nStored at ~/.config/gh-notif-bar/token (0600)."
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        field.stringValue = token ?? ""
        alert.accessoryView = field
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
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
        }
    }

    // MARK: Actions

    @objc private func openNotifications() {
        NSWorkspace.shared.open(URL(string: "https://github.com/notifications")!)
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
        var req = URLRequest(url: URL(string: "https://api.github.com/notifications")!)
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
        renderBadge(state: .count(notifications.count))

        let currentIDs = Set(notifications.compactMap { $0["id"] as? String })
        if hasFetchedOnce {
            for n in notifications {
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

    // MARK: Badge

    private enum BadgeState {
        case idle
        case count(Int)
        case error
        case needsToken
    }

    private func renderBadge(state: BadgeState) {
        guard let button = statusItem.button else { return }
        let icon = NSImage(systemSymbolName: "bell.fill", accessibilityDescription: "GitHub Notifications")
        icon?.isTemplate = true
        button.image = icon
        button.imagePosition = .imageLeading
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
