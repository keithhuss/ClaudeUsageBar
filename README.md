# ClaudeUsageBar

A tiny macOS menu-bar app that mirrors the Claude desktop client's usage panel — the
5-hour limit, weekly (all models), and weekly Fable bars — so you can watch your quota
while working in Xcode.

The menu bar shows the 5-hour percentage (e.g. `24%`, red at ≥90%). Clicking it opens a
panel with all the bars, reset times, and controls:

- **Window button (header):** shows/hides an optional floating window with the same
  bars — always on top (even over Xcode), draggable, remembers its position. Closing
  the window keeps the app running; clicking the Dock icon reopens it.
- **Refresh:** immediate fetch (bypasses the rate-limit cooldown).
- **Quit:** the only way the app exits.
- **Start at login:** installs a LaunchAgent (`com.keith.ClaudeUsageBar`) that runs a
  copy of the binary from `~/Library/Application Support/ClaudeUsageBar/` at every
  login. Untick to remove both. Note: after rebuilding the app, untick/re-tick once to
  refresh the installed copy; the login copy triggers one new Keychain prompt on first
  run (click Always Allow).

## One-time setup

The app reads your Claude Code OAuth token from the macOS Keychain and calls the same
usage endpoint the desktop client uses. The token minted by the **Xcode integration**
doesn't include usage access (`user:profile` scope), so the Claude Code **CLI** must be
logged in once:

1. Install Claude Code in Terminal:
   ```sh
   curl -fsSL https://claude.ai/install.sh | bash
   ```
2. Run `claude`, log in with your Claude account when the browser opens, then quit it.
3. Done — you never need to run the CLI again. The app copies the token into its own
   Keychain item (`ClaudeUsageBar-credentials`) and refreshes it itself from then on.

## Running

```sh
cd ClaudeUsageBar
swift run
```

The first run triggers a Keychain permission dialog — click **Always Allow**. Then tick
**Start at login** in the panel and you can close the Terminal for good.

The app runs as a regular app (Dock icon) rather than a menu-bar-only accessory — as an
unbundled binary, accessory mode never connected to the window server on this machine.
Menu-bar managers like Bartender may hide the gauge icon by default; look for
ClaudeUsageBar in Bartender's hidden items and set it to Always Show.

## Polling & rate limits

- Polls every **5 minutes**, plus whenever the panel opens or Refresh is clicked.
  (Polling every minute got the account rate-limited overnight — don't lower this.)
- On a 429 the app backs off (honors `retry-after`, minimum 5 minutes) and shows
  "Rate limited — retrying at …". It recovers automatically.
- OAuth token refreshes are attempted at most once per 10 minutes.

## Notes / caveats

- **Undocumented endpoint.** The data comes from `api.anthropic.com/api/oauth/usage`
  (the endpoint behind Claude Code's `/usage`). The parser reads the `limits` array —
  session / weekly_all / weekly_scoped entries — with a fallback for the older
  top-level bucket shape. A breaking change there would need a small code update.
- **Token handling.** Access tokens expire every few hours; the app refreshes them with
  the stored refresh token (Claude Code's public OAuth client id) and keeps its copy in
  its own Keychain item so it never overwrites Claude Code's. If the panel ever shows
  "token expired," running `claude` once in Terminal re-seeds it.
