# AGENTS.md

## Purpose

Treat GitLab Alert as production software. Optimize for correctness,
simplicity, maintainability and predictable native macOS behavior.

## Working agreement

- Use Jujutsu and work on the `main` bookmark. This repository explicitly
  overrides the generic branch-per-change rule.
- Before a non-trivial change, state the bounded plan, affected files, expected
  behavior and material risks. Wait for Alberto's confirmation.
- Keep unrelated improvements out of the implementation. Report them
  separately.
- Use Conventional Commit descriptions and keep commits focused.
- Never force-push, rewrite published history or overwrite a published release.

## Start with the whole user flow

Before editing, enumerate every producer and consumer of the state being
changed. At minimum inspect:

1. GitLab API query and decoding.
2. Snapshot and diff behavior.
3. Persistence and restoration after relaunch.
4. `AppModel` derived state.
5. Popover rows and section counts.
6. Detail window rows, filters, inspector and context actions.
7. Menu bar number, unread dot and accessibility label.
8. macOS notification creation and click routing.
9. Settings and documentation.

A feature is incomplete when it updates a row but leaves a badge, count,
notification, restored state or alternate screen inconsistent.

## Alert-state invariants

- GitLab remote state and local read state are separate concepts.
- Marking an alert as seen must never write to GitLab.
- A seen repository failure stays visible in the full detail workspace because
  the pipeline is still failing.
- The popover is an inbox: acknowledged repository failures disappear from its
  Repositories section.
- Popover section counts and the menu bar count include only actionable,
  unacknowledged items.
- Acknowledging a repository failure also acknowledges its matching unread
  pipeline-failed activity event, so the menu bar unread dot can clear.
- Recovery removes the acknowledgement. A later failure must become unread and
  notify again.
- Opening a popover, expanding a section or selecting a row never marks it as
  seen. Only an explicit action does.
- Seen state must survive relaunch and account changes must clear it.

Every change to alert state requires tests for the applicable invariants above.

## GitLab API rules

- Verify endpoint and filter semantics against current official GitLab
  documentation before changing API behavior.
- Reviewer and assignee are distinct merge-request roles. Fetch both when the
  product promises work needing the user's attention, and deduplicate overlap.
- A passing token verification proves only `/user`; dashboard queries and their
  scopes need their own tests.
- Changing the GitLab origin is an account boundary: cancel old work, clear
  account-derived state, replace the client, then accept a new token.

## macOS UI rules

- Inventory every route that opens a surface: status-item left click,
  right-click menu, Finder reopen, notification click, See All and Settings.
- Do not validate a menu bar launch with `open App.app` when the app is already
  running; it triggers the Finder reopen flow and can open the detail window.
  Launch the executable directly after terminating the previous process.
- Any local build or release command that stops the running app must be followed
  by a direct relaunch of `/Applications/GitLabAlert.app/Contents/MacOS/GitLabAlert`
  before the task is considered complete.
- Use documented SwiftUI/AppKit APIs before adding view-hierarchy or window
  hacks. Confirm placement requirements in Apple's documentation.
- Automated builds and tests do not prove visual behavior. Render web UI and
  manually inspect native surfaces when layout or interaction changes.
- Keep the popover compact and action-oriented. Preserve complete operational
  state in the detail window.

## Signing, Gatekeeper and installation

- Distinguish stable local signing from public trust. The self-signed identity
  preserves Keychain ACLs and notification permission across builds, but it is
  not a Developer ID certificate and the app is not notarized.
- Test the distributed artifact, not only `/Applications/GitLabAlert.app` built
  locally. Verify the mounted DMG, embedded signature and published checksum.
- Document the current Gatekeeper flow honestly: try the app, use **System
  Settings → Privacy & Security → Open Anyway**, and if the self-signed bundle
  remains blocked run:

  ```sh
  xattr -dr com.apple.quarantine "/Applications/GitLabAlert.app"
  ```

- Prefer the targeted quarantine removal above `xattr -cr`, which clears every
  extended attribute.
- Never claim that right-click Open or Open Anyway is sufficient without
  testing the downloaded release on a clean/quarantined path.

## Release gate

Before publishing:

1. Confirm the intended semantic version and bump both bundle version fields.
2. Run `bash bin/test.sh`.
3. Run `bash bin/make-release.sh`.
4. Verify DMG and ZIP exist and the app inside the mounted DMG passes
   `codesign --verify --deep --strict`.
5. Scan tracked files and history for tokens, signing material and secrets.
6. Fetch `origin`; confirm the local `main` bookmark is based on current
   `main@origin`.
7. Push with `jj git push --bookmark main`.
8. Publish a new immutable GitHub release with DMG and ZIP assets.
9. Verify repository visibility, release asset names/digests, GitHub Pages,
   canonical homepage and live download links.
10. Confirm `main == main@origin` and the working copy is clean.

Do not say “published”, “installed” or “verified” until the corresponding
remote, filesystem or runtime check has completed successfully.

## Website rules

- Use the real app identity and real supported behavior. Do not invent user
  names, repositories, notifications or metrics that could be mistaken for
  product screenshots.
- Label interactive demonstrations as demonstrations.
- Keep assets local, avoid analytics and external runtime dependencies, support
  narrow screens and `prefers-reduced-motion`.
- Validate HTML and inspect the rendered desktop and mobile layouts before
  publishing.
