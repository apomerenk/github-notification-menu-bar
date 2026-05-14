# GitHub Notifications Menu Bar

A tiny macOS menu bar app that shows your GitHub unread-notifications count and pops a system notification when new ones arrive. That's it. Inspired by [Trailer](https://github.com/ptsochantaris/trailer) but stripped down.

![icon](https://img.shields.io/badge/macOS-12+-blue)

## How it works

- Polls `https://api.github.com/notifications` (default every 60s, honors GitHub's `X-Poll-Interval` header).
- Menu bar shows a tray icon + unread count. Icon disappears entirely when the count is 0.
- New notifications fire macOS banner alerts. Clicking the banner — or the menu — opens [github.com/notifications](https://github.com/notifications).
- Token lives at `~/.config/gh-notif-bar/token` (mode `0600`), entered via the menu's "Set Token…" item.
- The first poll after launch is silent (it just seeds the seen-set) so you don't get a flood of banners on startup.

States shown in the menu bar:

| Badge | Meaning |
|---|---|
| _hidden_ | 0 unread |
| `📥 3` | 3 unread |
| `📥 ?` | no token configured |
| `📥 !` | network/API error (check Console for details) |

## Setup

### Requirements

- macOS 13+
- Xcode command line tools (`xcode-select --install`) — only needed if building from source
- A GitHub personal access token with the `notifications` scope (classic), or a fine-grained token with **Notifications: read**

### Install via Homebrew

```sh
brew tap apomerenk/tap
brew install --cask github-notifications-menu-bar
open -a GitHubNotifications
```

### Build from source

```sh
git clone https://github.com/apomerenk/github-notification-menu-bar.git
cd github-notification-menu-bar
./build.sh
open build/GitHubNotifications.app
```

To install to `/Applications`:

```sh
cp -R build/GitHubNotifications.app /Applications/
```

### First run

1. macOS will ask permission to send notifications — allow.
2. A token dialog appears. Paste your PAT and hit Save.
3. The icon shows up if you have unread notifications. If you don't, mark something unread on github.com and click "Refresh Now" to confirm it's working.

To get the menu back when the icon is hidden (count is 0), re-launch the app from Spotlight or Finder — `applicationShouldHandleReopen` forces it visible again.

## Auto-launch on login

Click the menu bar icon → **Launch at Login** to toggle. macOS may prompt for permission the first time. (Fallback: System Settings → General → Login Items → `+` → add `GitHubNotifications.app`.)

## Releases

Tagged commits cut a release: `git tag v1.2.3 && git push --tags` triggers [.github/workflows/release.yml](.github/workflows/release.yml), which builds the app, zips it, and uploads it to a GitHub release. The Homebrew tap cask points at that artifact.

## Files

- [main.swift](main.swift) — the whole app (status item, polling, notifications, token storage)
- [Info.plist](Info.plist) — bundle config; `LSUIElement` keeps it out of the Dock
- [build.sh](build.sh) — `swiftc` build + `.app` bundle assembly + ad-hoc codesign
