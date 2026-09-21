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
ask for it from the About panel, Sparkle fetches
`https://github.com/AlbertoBarrago/gitlab-alert/releases/latest/download/appcast.xml`,
the signed release feed, and compares it with this build's version. It carries
**no token, no account, no identifier and no payload** — the request is
anonymous. An update is applied only if its EdDSA signature verifies against
`SUPublicEDKey` in `Info.plist` and the new bundle carries the same signing
identity as the running one: a tampered or substituted archive is refused, not
installed. Turning off **Settings
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
| GitLab origin, polling intervals, repository scope, UI preferences | `~/Library/Preferences/com.alBz.GitLabAlert.plist` | owner-only |
| Last dashboard, pipeline watermarks, activity log, seen event IDs | `~/Library/Application Support/GitLabAlert/state.json` | directory `0700`, file `0600`, written atomically |
| Window and view selection | memory only | — |

Up to 0.1.7 these lived inside the App Sandbox container at
`~/Library/Containers/com.alBz.GitLabAlert/Data`. From 0.1.8 the app is no
longer sandboxed (see § Process isolation), so they sit in the usual per-user
locations; the first 0.1.8 launch imports what the container held, and leaves
the container in place rather than deleting it.

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

The app runs under the **hardened runtime**, and from 0.1.8 **not** in the App
Sandbox. It has one entitlement (`GitLabAlert.entitlements`):

- `com.apple.security.cs.disable-library-validation`

Both facts follow from in-app updates. Sparkle replaces the bundle in place,
which a sandboxed app can only do through Sparkle's two XPC services, and those
are more moving parts than the containment buys in a bundle that is assembled
and signed by a shell script. Library validation then has to be off because the
hardened runtime requires every loaded library to share the process's Team ID,
and a self-signed certificate has none: with it on, the embedded
`Sparkle.framework` is refused and the app does not launch.

What this changes honestly: the app can now read and write your home directory
as your user, where before it could not leave its container. What it actually
does with that is unchanged and inspectable — one preferences plist, one state
file, one Keychain item.

There is still no incoming network, no camera,
microphone, contacts, calendar, location or Apple Events. It is a menu bar
accessory (`LSUIElement`) with no Dock icon, and it starts at login only if you
enable that, through `SMAppService` (`LoginItem.swift`).

## Supply chain and provenance

- **One third-party dependency.** [Sparkle](https://github.com/sparkle-project/Sparkle),
  since 0.1.8, for in-app updates: it is resolved by SwiftPM as a signed
  xcframework, embedded in `Contents/Frameworks` and re-signed with this
  project's identity by `bin/embed-sparkle.sh`. Everything else that ships is in
  this repository. An update it offers is applied only against the EdDSA public
  key pinned in `Info.plist`, whose private half never leaves the release
  workflow's secret.
- **Reviewable surface.** The network client, credential handling, persistence
  and diffing live in `GitLabKit/`, a UI-free local package with its own tests.
- **Builds from source.** `bash bin/make-app.sh` produces the app with the Swift
  toolchain and `codesign`; Xcode is not required.
- **Releases** are built by `.github/workflows/release-macos.yml` from a tag,
  after the test suite passes. The workflow refuses to publish if the tag and
  `Info.plist` disagree, if the signing identity is missing, so a release is
  never ad-hoc signed, or if the appcast comes out unsigned.
  `SHA256SUMS.txt` is published with the DMG and the ZIP, and `appcast.xml`
  alongside them is the update feed itself.
- **Signing.** Releases are signed with the project's stable self-signed
  certificate. They are **not Apple-notarized**, which requires a paid Developer
  ID: on first launch macOS blocks the app until it is approved under
  **System Settings → Privacy & Security → Open Anyway**. If your organization
  requires notarized software, build from source instead — the requirement is
  about the distribution channel, not about what the app does.
- **Single maintainer.** This is a single-owner project. There is no second
  reviewer on commits, which is a fact worth weighing: the mitigation offered
  here is a small, nearly dependency-free, auditable codebase and a build you can
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
cat GitLabAlert.entitlements                                    # entitlement surface
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
