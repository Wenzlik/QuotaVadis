# QuotaVadis

Your AI coding limits, at a glance. A small macOS menu bar app that shows how much of your
Claude Code, Codex and Cursor quota is left, what it costs, and when it resets.
An iOS companion synced over iCloud is planned.

## Download

Recommended for first-time install: the notarized **DMG** from
[zmrhal.cz/quotavadis](https://zmrhal.cz/quotavadis/) — open it and drag
`QuotaVadis.app` onto the Applications shortcut.

In-app updates keep using the **zip** via Sparkle (same appcast as before).
You do not need the DMG again after the first install.

![icon](Apps/Mac/Resources/Assets.xcassets/AppIcon.appiconset/icon_128.png)

## What it shows

- One row per tool: session / weekly / monthly windows as bars, reset countdowns, plan and seat.
- Extra usage and credits against their caps, Codex limit resets available.
- Expand a row for the full picture: per-model windows, account, cost and tokens for today and
  the last 30 days, a dated daily chart, token mix, breakdown by model and by project.
- "View details" opens a resizable dashboard window per account with larger charts.
- Menu bar number is yours to choose: highest usage, or one specific window.

## Where the data comes from

On first launch a short welcome picks the tools to track and connects Claude; nothing is read before you
finish it. Claude uses a login of QuotaVadis's own: "Continue in browser", approve, then paste the code
Claude shows back into the app (there is no automatic return — Anthropic has no redirect for this app). The
login lives in a Keychain item only QuotaVadis owns, so macOS stops asking for Keychain permission.
Reconnect or sign out any time in Settings ▸ Accounts. The other tools reuse the sessions they already keep:

| Tool | Credentials | Usage | Cost |
|---|---|---|---|
| Claude | QuotaVadis's own login (or, under advanced sources, Claude Code's Keychain item `Claude Code-credentials`) | `api.anthropic.com/api/oauth/usage` + `/profile` | local `~/.claude/projects/**/*.jsonl` |
| Codex | `~/.codex/auth.json` | `chatgpt.com/backend-api/wham/usage` | local `~/.codex/sessions/**/*.jsonl` |
| Cursor | Cursor.app `state.vscdb` | `cursor.com/api/usage-summary` (+ Grok Bot) | `cursor.com/api/dashboard/get-filtered-usage-events` |

Cost figures for Claude and Codex are estimates at API list prices (models.dev catalog, cached daily);
subscriptions are not billed per token. Cursor cost is what Cursor itself metered.

## Command line

The app bundles `quotavadis`; install the symlink from Settings ▸ General, or run it directly from
`/Applications/QuotaVadis.app/Contents/MacOS/quotavadis-cli`. Homebrew users can also `swift build -c release --product quotavadis` from a checkout.

```
quotavadis                  table of every tool
quotavadis --json           snapshots as JSON
quotavadis --watch 60       refresh in place
quotavadis --provider codex
quotavadis cost             30-day cost & token estimates
```

## No Claude Code? No problem

Claude limits can also come from a claude.ai web session: the Claude desktop app or Chrome are read automatically
(decrypting their cookie store with the app's Safe Storage key from your Keychain), or paste the `sessionKey` cookie in
Settings ▸ Accounts ▸ advanced Claude sources. Every organization with limits shows up as its own row.

## Build

Requires Xcode 26 and [xcodegen](https://github.com/yonaskolb/XcodeGen).

```sh
swift test                      # QuotaCore unit tests
swift run quotactl              # live table from your accounts
swift run quotactl --cost       # 30-day cost/token report
swift run quotactl --raw        # raw API responses
Scripts/install-local.sh        # build Release, install to ~/Applications, launch
Scripts/release.sh 0.x.y        # Developer ID archive → zip (Sparkle) + DMG (install)
Scripts/make-dmg.sh path/to/QuotaVadis.app   # DMG only, from an already signed+stapled app
```

`QuotaCore` (SwiftPM) holds models, fetchers, scanners and pricing; `Apps/Mac` is the SwiftUI menu bar app.

## Credits

Made by [Václav Zmrhal](https://zmrhal.cz). Data-source research owes a lot to
[CodexBar](https://github.com/steipete/CodexBar) (MIT). Not affiliated with Anthropic, OpenAI or Cursor.
