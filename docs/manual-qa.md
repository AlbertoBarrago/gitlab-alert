# Manual QA

A status item and a popover are not reliably driveable by an automated UI test, so this surface is
checked by hand. This file is the checklist. It is honest about being manual rather than pretending the
coverage exists somewhere else.

`bin/test.sh` runs both GitLabKit and app lifecycle tests. Automated coverage includes
concurrent refreshes, cancellation, account replacement, late catalog responses,
Keychain error handling through test stores, notification routing, and read-state
persistence. The native interactions below still require an installed build.

Run against a real build: `bash bin/make-app.sh && open /Applications/GitLabAlert.app`.

## First run

- [ ] No Dock icon appears. The glyph appears in the menu bar.
- [ ] With no token stored, the popover shows an onboarding call to action — not an error, not a spinner.
- [ ] Pasting an invalid token reports **"GitLab rejected the token"**, not a generic failure.
- [ ] Pasting a valid token resolves the login and avatar, and the popover populates.
- [ ] The token field never shows the real value again after saving, on any tab, after any relaunch.
- [ ] **No notifications fire on the first cycle**, even though the account has hundreds of existing
      stars. This is the baseline rule ([ADR 0007](adr/0007-watermark-invariant.md)) and it is the single
      most important thing on this page.

## Status item

- [ ] The glyph is legible in a light menu bar and in a dark one, and follows the system tint.
- [ ] With items awaiting action, a count renders beside the glyph.
- [ ] The count does not make the item jitter as digits change (monospaced digits).
- [ ] An unread star/fork/CI event shows the accent dot; opening the popover clears it.
- [ ] Left click toggles the popover. Right click opens the menu with Refresh, Open, Settings, Quit.
- [ ] Option-click forces an immediate refresh.
- [ ] ⌘-dragging the item to a new position survives a relaunch (autosave).
- [ ] Hiding the item from Settings actually hides it, and unhiding restores it.
- [ ] VoiceOver reads something useful, e.g. "GitLab Alert, 3 items need attention".

## Popover

- [ ] Opens adjacent to the status item, on every display, including a notched one.
- [ ] Opens correctly when triggered **before** the menu bar has laid out (the fallback anchor path).
- [ ] Clicking outside dismisses it. Escape dismisses it — check this after any change to key handling,
      because a stray `.onKeyPress` silently steals the built-in behaviour.
- [ ] A search field inside the popover can take focus and receive typed characters.
- [ ] Expanding a section animates the panel height rather than clipping or jumping.
- [ ] With all sections collapsed, the popover fits its content without scrolling or unused vertical space.
- [ ] Expanding content grows the popover until the active screen's visible height, then enables scrolling.
- [ ] Counts roll rather than snap when a value changes.
- [ ] Every section at zero shows a designed empty state, not a blank area.
- [ ] ↑/↓ move the selection, ⏎ opens the item on GitLab, ⌘R refreshes, ⌘, opens Settings.
- [ ] Rows show a hover state.
- [ ] Avatars load, and a monogram placeholder appears while loading and on failure.

## Detail window

- [ ] Opens from "See all", from a notification click, and from the status item menu.
- [ ] No Dock icon or ⌘-Tab entry appears while detail or Settings windows are open.
- [ ] ⌘W closes it, ⌘F focuses search, text is selectable, the Edit menu behaves.
- [ ] Sorting by each column works; the table stays responsive with a few hundred rows.
- [ ] The inspector follows the selection and "Open on GitLab" opens the right URL.
- [ ] Window size and position survive a relaunch.
- [ ] Opening it from a notification **selects the item that notification was about**.

## Notifications

- [ ] Authorization is requested at the **first real event**, not at launch.
- [ ] Denying authorization degrades to in-UI-only, and Settings explains the state and offers a route
      to System Settings.
- [ ] A star arrives as a banner naming the person, within one poll interval.
- [ ] A fork arrives as a banner.
- [ ] CI going red notifies; CI merely going from unknown to pending does **not**.
- [ ] Turning off a single kind in Settings stops that kind and leaves the others working.
- [ ] A burst (star a repo from several accounts) produces one summary notification, not one per star.
- [ ] Clicking a notification opens the detail window on the right item.
- [ ] No notification payload contains the token or any credential.

## Polling and power

- [ ] Opening the popover triggers an immediate refresh.
- [ ] Sleeping and waking the Mac does not produce a burst of duplicate notifications.
- [ ] Disconnecting the network shows the last snapshot with an honest timestamp — never an empty
      screen — and does not spin retries.
- [ ] Reconnecting refreshes promptly.
- [ ] On battery, the cadence widens (check with `bin/run-with-logs.sh`).
- [ ] Revoking the token on GitLab surfaces a readable error state, and does not crash.

## Persistence

- [ ] Quit and relaunch: no notifications replay for events already seen.
- [ ] `rm ~/Library/Application\ Support/GitLabAlert/state.json`, then relaunch: the app recovers,
      re-seeds, and notifies **nothing**.
- [ ] Corrupt that file (`echo '{' > …`) and relaunch: same as above, no crash.
- [ ] Rebuild with `bin/make-app.sh` and relaunch: **the token is still there and no Keychain prompt
      appears**. If it does, the signing identity is not stable — see
      [ADR 0004](adr/0004-stable-self-signed-signing.md).

## Scope changes

- [ ] Adding a repository to the watch set in Settings notifies nothing for its existing stars.
- [ ] Removing one stops its events.
- [ ] With 178 repositories, the picker's search and filters stay responsive while typing.
- [ ] The summary line reports the right "watching N of M".

## Known gaps

These are not covered anywhere and are accepted for now:

- `SMAppService` login-item registration behaves differently outside `/Applications`; only the installed
  build is meaningful to test.
- Popover placement across display reconfiguration (unplugging an external monitor while open).
- Whether GraphQL `search` connections are also billed against the 30/minute search limit; the embedded
  `rateLimit` field and the response headers will answer it after an hour of real use.

## Verification — 2026-09-11

- App lifecycle regression tests exercise late responses even when the transport ignores cancellation.
- Replacing an account clears cached history before verifying new credentials and silently seeds the next dashboard.
- A notification opens its exact event in Recent activity for every event kind.
- Failed state writes prevent notifications and leave the previous baseline intact.
- Opening the popover persists read events; unread history is restored on relaunch.
- Real Keychain integration tests are skipped when the test runner has no unlocked login Keychain.
- A signed diagnostic app with the release entitlements verified add/read/delete against the login Keychain; the Data Protection variant reproduced `errSecMissingEntitlement` and was removed.
- Authenticated GitLab polling, notification delivery, sleep/wake, and multiple-display placement require manual verification.

- Installed Release build signs and verifies with the local GitLab Alert Signing certificate.
- Runtime check: launched successfully with `NSRunningApplication.activationPolicy == .accessory`, including after reopening the detail window.
- The onboarding popover now measures its full content to include the bottom actions; long content remains scrollable.
- The menu bar mascot was rendered and inspected at 18 points on light and dark backgrounds, with and without the unread badge.
- Live diagnostics showed the 100-node repository query timing out at GitLab's gateway after 10.7 seconds; repository pages were reduced to 25 while retaining cursor pagination.
