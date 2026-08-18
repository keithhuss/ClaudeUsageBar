# ClaudeUsageBar

A tiny macOS menu-bar app that mirrors the Claude desktop client's usage panel — the
5-hour limit, weekly (all models), and weekly Fable bars — so you can watch your quota
while working in Xcode.

The menu bar shows the 5-hour percentage (e.g. `24%`, red at ≥90%). Clicking it opens a
panel with all the bars, reset times, and controls:

- **Window button (header):** shows/hides an optional floating window with the same
  bars — always on top (even over Xcode), draggable, remembers its position. Closing
  the window keeps the app running; clicking the Dock icon reopens it.
- **Refresh:** immediate fetch (bypasses the rate-limit cooldown and the poll-interval throttle).
- **Fast polling (Fable mode):** tick the box before a Fable session to poll every 5
  minutes instead of the normal cadence; untick when done.
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
3. Done. The app reads Claude Code's own Keychain item and, when it refreshes the
   token, writes the result back to that same item — see **Token handling** below for
   why it doesn't fork a private copy.

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

The `api/oauth/usage` rate-limit bucket appears to be shared across every client using
your OAuth token (Claude Code CLI, this app, etc.), so polling too aggressively — even
from a single app — can trip it. Polling cadence adapts instead of staying fixed:

- **Fast (5 min):** while "Fast polling (Fable mode)" is checked.
- **Normal (15 min):** default, whenever the Mac is actively in use.
- **Idle (30 min):** automatic, once the Mac has been idle 10+ minutes (checked via
  `CGEventSource.secondsSinceLastEventType`, no permissions needed). Any input resumes
  normal cadence on the next check.
- A lightweight 30-second tick timer just checks whether the current interval has
  elapsed since the last attempt — so a mode change (toggling Fable mode, or the Mac
  going idle/active) takes effect on the next tick rather than waiting for a stale timer.
- On system wake, polling is silently held off until `NWPathMonitor` confirms the network
  has been continuously reachable for 20 seconds — not a fixed timer — capped at 10
  minutes so a monitor glitch can't wedge polling forever. This matters because this app
  is typically the *only* client that ever refreshes its Keychain credential; refresh
  tokens are single-use, so a refresh attempted on a not-yet-stable connection can have
  its response lost after the server already rotated the token, killing it permanently
  with nothing else around to recover it. See **Token handling** below.
- On a 429 the app backs off (honors `retry-after`, minimum 5 minutes) and doubles the
  wait on each consecutive 429 (capped at 16×) so one hiccup can't cascade into a
  multi-hour lockout from retrying at full speed the moment each cooldown expires. The
  backoff resets on the next success. Shows "Rate limited — retrying at …" meanwhile.
- OAuth token refreshes are attempted at most once per 10 minutes (except the fast
  auth-failure retry below, which isn't subject to this).
- On a 401 whose refresh attempt fails, the app doesn't immediately assume the token
  is dead — most such failures turn out to be transient (a flaky refresh call, a
  momentary server hiccup) and clear up within a poll or two. It retries every 90
  seconds, showing "Reconnecting…" with the last-known bars still visible, for up to 20
  minutes before escalating to the "token expired" setup screen. The 20-minute clock
  resets on any success, and also resets if a *different* kind of failure (a 429, or a
  network exception) happens in between — otherwise a stale clock from an
  already-resolved incident could make a later, unrelated 401 escalate immediately
  instead of getting its own fresh 20 minutes. The 429 backoff multiplier has the same
  reset-on-a-different-failure-type behavior.
- Refresh (the button) always bypasses every throttle above, but never runs concurrently
  with an already-in-flight reload (automatic or manual) — otherwise both could read and
  try to refresh the same single-use refresh token, guaranteeing one of them fails.

## Notes / caveats

- **Undocumented endpoint.** The data comes from `api.anthropic.com/api/oauth/usage`
  (the endpoint behind Claude Code's `/usage`). The parser reads the `limits` array —
  session / weekly_all / weekly_scoped entries — with a fallback for the older
  top-level bucket shape. A breaking change there would need a small code update.
- **Token handling.** Access tokens expire every few hours; the app refreshes them with
  the stored refresh token (Claude Code's public OAuth client id). Refresh tokens are
  single-use/rotating, so refreshes are written back to whichever Keychain item
  (almost always Claude Code CLI's own — `Claude Code-credentials`, possibly with a
  config-dir suffix for the Xcode integration) the credential was read from, rather
  than forked into a private item. An earlier version *did* fork a private copy that
  refreshed independently of the CLI — since both sides were consuming the same
  single-use rotating token from two unsynced copies, whichever side refreshed first
  invalidated the other's, causing "Token expired and couldn't be refreshed" any time
  the CLI was used heavily (fixed 2026-08-13). The write is a merge, not a replace —
  Claude Code's real items carry extra fields this app doesn't model
  (`refreshTokenExpiresAt`, `subscriptionType`, `rateLimitTier`, `clientId`), so only
  the changed fields (`accessToken`, `refreshToken`, `expiresAt`) are updated in place;
  everything else in the JSON blob passes through untouched. If the panel ever shows
  "token expired," running `claude` once in Terminal re-seeds it — this is a fresh
  OAuth login, not a repair, so it works even if the stored token is fully dead.
- **If Keith never runs the CLI himself** (confirmed 2026-08-17), this app is the *sole*
  client touching that Keychain item — there's no other client to collide with it, so a
  dead token traces back to this app's own refresh call losing a race against a flaky
  network (see the wake-gating note above), or against *itself* (fixed 2026-08-17 — see
  Polling & rate limits above), not a collision with anything else.
- The legacy private `ClaudeUsageBar-credentials` item from before the 2026-08-13 fix is
  no longer read at all (removed 2026-08-17) — nothing has written to it since, so it
  could never again be the freshest candidate; reading it every poll was pointless.
