# GitHub Notifications Menu Bar

A tiny macOS menu bar app that shows your GitHub unread-notifications count and pops a system notification when new ones arrive. That's it. Inspired by [Trailer](https://github.com/ptsochantaris/trailer) but stripped down.

![icon](https://img.shields.io/badge/macOS-12+-blue)

## How it works

- Polls `https://api.github.com/notifications` (default every 60s, honors GitHub's `X-Poll-Interval` header).
- Menu bar shows a tray icon + unread count. Icon stays visible at 0; the count just hides.
- New notifications fire macOS banner alerts. Clicking the banner — or the menu — opens [github.com/notifications](https://github.com/notifications).
- Two tokens, each at `~/.config/gh-notif-bar/` (mode `0600`), entered via the menu's "Set Tokens…" item:
  - `notifications_token` — classic PAT, `notifications` scope (for unread/read rows + banners)
  - `pr_token` — classic PAT with `repo` scope, or a fine-grained PAT with `Pull requests: read` + `Metadata: read` (for the "Needs your review" section). Classic + `repo` is broader but works for org repos out of the box; fine-grained needs org admin approval.
- The first poll after launch is silent (it just seeds the seen-set) so you don't get a flood of banners on startup.

States shown in the menu bar:

| Badge | Meaning |
|---|---|
| `📥` | 0 unread |
| `📥 3` | 3 unread |
| `📥 ?` | no token configured |
| `📥 !` | network/API error (check Console for details) |

## Setup

### Requirements

- macOS 13+
- Xcode command line tools (`xcode-select --install`) — only needed if building from source
- A GitHub **classic** PAT with the `notifications` scope (required for the notifications list + banners).
- Optionally a second PAT for the "Needs your review" section — easiest is a **classic** PAT with `repo` scope (broad but works without admin help), or a **fine-grained** PAT with `Pull requests: read` + `Metadata: read` if your org allows fine-grained PATs. Without this token, the PR section is just hidden — notifications still work.

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
3. The icon appears in the menu bar. If everything is read, you'll see the bare tray glyph; the unread count appears beside it as soon as one arrives.

## Auto-launch on login

Click the menu bar icon → **Launch at Login** to toggle. macOS may prompt for permission the first time. (Fallback: System Settings → General → Login Items → `+` → add `GitHubNotifications.app`.)

## Releases

Releases are label-driven. To ship a change, add one of these labels to the PR before merging:

| Label | Bump |
|---|---|
| `release:patch` | 1.2.3 → 1.2.4 |
| `release:minor` | 1.2.3 → 1.3.0 |
| `release:major` | 1.2.3 → 2.0.0 |

No label → no release. On merge, [.github/workflows/release.yml](.github/workflows/release.yml) bumps `CFBundleShortVersionString` in [Info.plist](Info.plist), tags the commit, builds the `.app`, attaches a zip to a GitHub release, and pushes the new version + sha256 to the `apomerenk/homebrew-tap` cask. `brew upgrade --cask github-notifications-menu-bar` picks it up.

Release notes are the PR title + body — write them for the eventual reader of the changelog.

## Files

- [main.swift](main.swift) — the whole app (status item, polling, notifications, token storage)
- [Info.plist](Info.plist) — bundle config; `LSUIElement` keeps it out of the Dock
- [build.sh](build.sh) — `swiftc` build + `.app` bundle assembly + ad-hoc codesign
