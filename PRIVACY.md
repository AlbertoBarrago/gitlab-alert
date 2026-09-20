# Privacy

GitLab Alert collects nothing.

There is no analytics, no telemetry, no crash reporting, no advertising
identifier, no account, no licence check and no update check. The project runs
no servers, so there is no place for your data to arrive even in principle. The
app talks to the GitLab instance you configure and to nothing else — see
[`SECURITY.md`](SECURITY.md) for the exact list of requests and the file that
implements each one.

This document is written to be forwarded to a security or data-protection
reviewer.

## Who is who

- **You** run the app on your Mac and hold the GitLab personal access token.
- **Your GitLab instance** — GitLab.com or your self-managed installation —
  already holds the data the app displays. The app does not change that
  relationship; it is another client, like your browser.
- **The maintainer of this project receives nothing.** No data, no identifiers,
  no logs, no error reports. Under GDPR terms, the project is not a processor of
  your data: it never receives any.

## Data the app handles

| Category | Example | Where it lives | Leaves your Mac? |
| --- | --- | --- | --- |
| Credential | GitLab personal access token, `read_api` | macOS Keychain, device-only, not synced to iCloud | Only to your configured GitLab origin, as the `PRIVATE-TOKEN` header |
| Account data | your username, display name, avatar URL | in memory, and in the local state file | No |
| Work items | titles, authors, reviewers, URLs and states of merge requests and issues assigned to or authored by you | local state file | No |
| Projects | names, visibility, star and fork counts, last pipeline state | local state file | No |
| Preferences | GitLab origin, polling intervals, repository scope, UI choices | `UserDefaults` | No |
| Notification state | watermarks, seen event IDs | local state file | No |

The app is sandboxed, so everything it writes stays in its own container at
`~/Library/Containers/com.alBz.GitLabAlert/Data`:

- `<container>/Library/Application Support/GitLabAlert/state.json` — directory
  `0700`, file `0600`, plain JSON, no credential in it.
- `<container>/Library/Preferences/com.alBz.GitLabAlert.plist` — preferences.
- Login Keychain — the token only, and the only thing the app owns outside the
  container.

## Third parties

None are involved by this project. Two cases are worth stating explicitly,
because they depend on how your instance is configured:

- **Avatars.** If your GitLab instance has Gravatar or Libravatar enabled (the
  GitLab default), it returns `gravatar.com` URLs for users without an uploaded
  picture, and GitLab.com serves avatars from `avatars.gitlabusercontent.com`.
  The app loads those images **anonymously**: the token is attached only to
  avatar URLs on your own origin, and never survives a redirect off it. Loading
  such an image discloses your IP address to that host, exactly as your browser
  would when you view the same page on GitLab. Disabling Gravatar on your
  instance removes the case entirely.
- **Opening a link.** Clicking an item opens it in your default browser. The app
  refuses to open anything that is not https on your configured host.

## Notifications

Notifications are produced locally by macOS. There is no push service and the
app holds no push entitlement, so notification text never passes through Apple
or anyone else. The text includes the title of the item that changed, which
means it can appear on the lock screen; macOS notification settings control
that per app.

The first successful refresh after installation establishes a silent baseline,
so a new installation never notifies about pre-existing work.

## Retention and deletion

The app keeps the last dashboard, a rolling activity log capped at 200 entries
and up to 1000 seen event IDs. Nothing is retained anywhere else, because there
is nowhere else.

To remove everything: revoke the token on your instance, delete the app, remove
`~/Library/Containers/com.alBz.GitLabAlert`, and delete the
`com.alBz.GitLabAlert` Keychain item. Revoking the token is the step that matters and takes effect
immediately, independently of the app.

## Changes

This document describes the app as implemented in this repository. Any change to
what leaves your Mac would be a change to the code in
`GitLabKit/Sources/GitLabKit/Client/`, visible in the commit history and
reflected here.
