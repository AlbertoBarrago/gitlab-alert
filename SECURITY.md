# Security

GitLab Alert is a read-only macOS menu bar client for GitLab. It has no server
component, no account system and no backend operated by this project: it talks
to the GitLab instance you configure, and to nothing else.

This document describes what the app does with your credential and your data,
so that you — or your security team — can authorize it without having to read
the source. Every claim below names the file that implements it, so it can be
verified rather than trusted. Unless stated otherwise, it describes `main` at
the time of writing.

## Threat model

The credential at stake is a GitLab personal access token (PAT) with the
`read_api` scope, on an instance the user already has access to. The risks this
design takes seriously, in order:

1. The token reaching any host other than the configured GitLab instance.
2. The token reaching disk, a log, a backup or a cloud sync in readable form.
3. Another local process, or another build of this app, reading the token.
4. Data fetched from GitLab (titles of merge requests, issues, project names)
   persisting on the Mac in a way the user does not expect.

Out of scope: an attacker with root, a compromised GitLab instance, or physical
access to an unlocked Mac. The app cannot defend against a host that is already
trusted with the credential.

## The token

| Property | Value | Where |
| --- | --- | --- |
| Scope requested | `read_api` only; no write scope is used or requested | `README.md`, `GitLabClient` issues only `GET` |
| Storage | macOS Keychain, `kSecClassGenericPassword`, service `com.alBz.GitLabAlert` | `GitLabKit/Sources/GitLabKit/Store/KeychainTokenStore.swift` |
| Accessibility | `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` | same file |
| iCloud sync | Not synchronizable: the item is never in an iCloud Keychain or in an encrypted backup | same file |
| Plaintext on disk | Never. It is not in `UserDefaults`, not in the state file, not in a config file | `Preferences.swift`, `FileStateStore.swift` |
| In logs | Never. `KeychainError` deliberately carries no token in any case payload, message or description | `KeychainTokenStore.swift` |
| In the UI | Write-only. It is not shown again after saving, and no view reads it | `AccountSettingsView.swift` |
| Deletion | Signing out and changing the GitLab origin both delete it before anything else happens | `AppModel.updateGitLabBaseURL`, `AppModel` sign-out path |

Access to the Keychain item is bound to the app's code-signing designated
requirement, which is why release builds and local builds use a stable signing
identity: a different identity cannot read the item.

## What leaves your Mac

Every request is a `GET` to the origin you configured, authenticated with
GitLab's `PRIVATE-TOKEN` header:

| Endpoint | Purpose |
| --- | --- |
| `GET {origin}/api/v4/user` | verify the token, resolve your username and avatar |
| `GET {origin}/api/v4/merge_requests` | open merge requests where you are reviewer, assignee or author |
| `GET {origin}/api/v4/issues` | open issues assigned to you |
| `GET {origin}/api/v4/projects` | projects you are a member of, filtered by your repository scope |
| `GET {origin}/api/v4/projects/{id}/pipelines` | the latest pipeline of each watched project |

Implemented in `GitLabKit/Sources/GitLabKit/Client/GitLabClient.swift`. Page
size and pipeline concurrency are clamped so a preference cannot turn a refresh
into an unbounded burst (`DashboardRequestOptions`).

**Avatars are the one request that may go elsewhere.** Avatar URLs come from
the API payload, and GitLab does not guarantee they point at your instance:
GitLab.com serves them from `avatars.gitlabusercontent.com`, and a self-managed
instance with Gravatar or Libravatar enabled — the shipped GitLab default —
returns `gravatar.com` URLs for users who never uploaded a picture. The token is
therefore attached **only** when the avatar URL is on the configured origin
itself: same host, same effective port, https on both sides. Anything else is
fetched anonymously, and every redirect hop is re-evaluated under the same rule
so a bounce off the instance cannot carry the credential along.
See `GitLabKit/Sources/GitLabKit/Client/AvatarRequest.swift` and
`GitLabAlert/Core/AvatarLoader.swift`, covered by `AvatarRequestTests`.

If you want zero third-party avatar traffic, disable Gravatar on your instance
(**Admin → Settings → General → Account and limit → Gravatar enabled**); the app
then never sees a URL outside your origin.

**One request goes to GitHub: the update check.** Every six hours, and when you
ask for it from the About panel, the app calls
`GET https://api.github.com/repos/AlbertoBarrago/gitlab-alert/releases/latest`
to compare the published tag with this build's version. It carries **no token,
no account, no identifier and no payload** — the request is anonymous, and the
test suite asserts that no credential header is attached. Turning off **Settings
→ General → Check for new versions automatically** stops it entirely; the About
panel's manual check still works, because asking explicitly is consent. A tag
the app cannot parse is ignored rather than announced, and a release URL that is
not https is refused. See `GitLabKit/Sources/GitLabKit/Update/ReleaseChecker.swift`.

Nothing else goes out. There is **no** telemetry, analytics, crash reporting,
licensing check or "phone home" of any kind, and no third-party SDK that could
add one: both `Package.swift` files declare `dependencies: []`. The only other
network activity the app can cause is opening a link in your default browser,
and it refuses to open any URL that is not https on the configured host
(`AppModel.openOnGitLab`).

## Transport

- The origin must be `https`. Anything else is rejected and replaced with the
  default (`Preferences.normalizedGitLabBaseURL`).
- There is no App Transport Security exception in `Info.plist`, so TLS is
  validated against the system trust store with the platform defaults. A
  self-managed instance behind an internal CA works once that CA is trusted by
  macOS; the app does not accept a certificate the system would reject, and
  offers no switch to disable validation.
- API responses are never cached: the client uses an ephemeral `URLSession`
  with `urlCache = nil` (`URLSessionHTTPClient.swift`). Avatar images are cached
  in memory only (`AvatarLoader.swift`).

## What stays on your Mac

| Data | Location | Protection |
| --- | --- | --- |
| Token | login Keychain | Keychain, device-only, app identity bound |
| GitLab origin, polling intervals, repository scope, UI preferences | `<container>/Library/Preferences/com.alBz.GitLabAlert.plist` | sandbox container, owner-only |
| Last dashboard, pipeline watermarks, activity log, seen event IDs | `<container>/Library/Application Support/GitLabAlert/state.json` | sandbox container, directory `0700`, file `0600`, written atomically |
| Window and view selection | memory only | — |

`<container>` is `~/Library/Containers/com.alBz.GitLabAlert/Data`: the app is
sandboxed, so everything it writes stays inside its own container and it cannot
read the rest of your home directory. The Keychain item is the only thing it
owns outside it.

`state.json` is plain JSON and contains **no credential**, but it does contain
data fetched from GitLab: titles of merge requests and issues, project names,
usernames and pipeline states. It is not encrypted by the app — at rest it is
protected by file permissions and by FileVault, which is the appropriate control
on a managed Mac. The activity log is capped at 200 entries and seen IDs at
1000 (`FileStateStore.swift`).

Notifications are local (`UNUserNotificationCenter`), never remote push — the
app has no push entitlement. Their text includes the title of the item that
changed, so it is visible on the lock screen unless macOS notification settings
say otherwise.

Diagnostic logging goes to the macOS unified log through `os.Logger` under the
subsystem `com.alBz.GitLabAlert`. Only endpoint paths, HTTP status codes and
error descriptions are marked public; no token and no item content is logged.

### Removing everything

1. Revoke the token on your instance, at `/-/user_settings/personal_access_tokens`.
2. Quit the app and delete `/Applications/GitLabAlert.app`.
3. `rm -rf ~/Library/Containers/com.alBz.GitLabAlert` — the container holds both
   the state file and the preferences.
4. Delete the `com.alBz.GitLabAlert` item in Keychain Access, if it is still there.

Revoking the token on GitLab is the step that matters; it is immediate and does
not depend on the app.

## Process isolation

The app runs in the macOS App Sandbox with exactly two entitlements
(`GitLabAlert.entitlements`):

- `com.apple.security.app-sandbox`
- `com.apple.security.network.client` — outgoing connections only

No file system access beyond its own container, no incoming network, no camera,
microphone, contacts, calendar, location or Apple Events. It is a menu bar
accessory (`LSUIElement`) with no Dock icon, and it starts at login only if you
enable that, through `SMAppService` (`LoginItem.swift`).

## Supply chain and provenance

- **No third-party code.** Zero package dependencies; every line that ships is
  in this repository.
- **Reviewable surface.** The network client, credential handling, persistence
  and diffing live in `GitLabKit/`, a UI-free local package with its own tests.
- **Builds from source.** `bash bin/make-app.sh` produces the app with the Swift
  toolchain and `codesign`; Xcode is not required.
- **Releases** are built by `.github/workflows/release-macos.yml` from a tag,
  after the test suite passes. The workflow refuses to publish if the tag and
  `Info.plist` disagree or if the signing identity is missing, so a release is
  never ad-hoc signed. `SHA256SUMS.txt` is published with the DMG and the ZIP.
- **Signing.** Releases are signed with the project's stable self-signed
  certificate. They are **not Apple-notarized**, which requires a paid Developer
  ID: on first launch macOS blocks the app until it is approved under
  **System Settings → Privacy & Security → Open Anyway**. If your organization
  requires notarized software, build from source instead — the requirement is
  about the distribution channel, not about what the app does.
- **Single maintainer.** This is a single-owner project. There is no second
  reviewer on commits, which is a fact worth weighing: the mitigation offered
  here is a small, dependency-free, auditable codebase and a build you can
  reproduce yourself.

## Known limitations

- Release artifacts are signed but not notarized (see above).
- `state.json` is not encrypted at rest by the app.
- Avatars in the detail window are always fetched anonymously, so on a private
  instance they fall back to a monogram instead of loading.
- GitLab instances hosted under a URL sub-path are not supported.
- The app cannot restrict what a `read_api` token can reach; scope the token on
  the GitLab side if your policy requires it.
- The update check discloses this Mac's IP address to GitHub, as any request
  would. Turn it off if that is not acceptable in your environment.

## Verifying these claims

The checks a reviewer usually wants, in the order they usually want them:

```sh
grep -rn "PRIVATE-TOKEN\|Authorization" --include="*.swift" .   # every use of the credential
grep -rn "http" --include="*.swift" GitLabKit/Sources           # every outbound call
grep -rn "api.github.com" --include="*.swift" .                 # the one non-GitLab host
grep -n "dependencies" Package.swift GitLabKit/Package.swift    # third-party code
cat GitLabAlert.entitlements                                    # sandbox surface
bash bin/test.sh                                                # the suite, including AvatarRequestTests
```

`docs/architecture.md` describes the design, including the § Security boundaries
section, and `PRIVACY.md` covers the data-protection side.

## Reporting a vulnerability

Please report privately through GitHub Security Advisories:
<https://github.com/AlbertoBarrago/gitlab-alert/security/advisories/new>.

Please include the version, macOS version, whether the instance is GitLab.com or
self-managed, and the steps to reproduce. You will get an acknowledgement within
a few days. This is a single-maintainer project with no paid support: fixes are
best-effort, and the issue will be disclosed in the release notes once a fixed
version is published.

Do not open a public issue for something that exposes a credential.
