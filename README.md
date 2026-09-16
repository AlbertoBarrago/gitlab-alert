# GitLab Alert

A macOS menu bar app that keeps the GitLab work needing your attention in the
corner of your screen, instead of in a browser tab. It lives in the menu bar
only, with no Dock icon, and shows you:

- **Merge requests awaiting you**: merge requests assigned to you, review requests and merge requests you authored
- **Open issues**: issues assigned to you
- **Pipeline state**: the latest pipeline of the GitLab projects you watch
- **Repository activity**: your projects, including star and fork counts when GitLab provides them

GitLab Alert works with GitLab.com and self-managed GitLab instances. It polls
in the background, retains the last successful dashboard while offline, and
only notifies you when tracked work or pipeline state changes.

**[Visit the product page](https://albz.it/gitlab-alert/)** for
the quickest overview and installation guide.

GitLab Alert is free. If it earns a place in your menu bar,
**[leave it a star](https://github.com/AlbertoBarrago/gitlab-alert)**. ⭐

**Status:** under active development. Prebuilt releases are signed but not
Apple-notarized; see the installation steps below before the first launch.

<!-- TODO: screenshots once the popover UI settles -->

## Requirements

- macOS 14 (Sonoma) or later
- A Swift 6 toolchain (`swift --version` should report 6.0+)

There is no `.xcodeproj` and Xcode is not required. The project uses SwiftPM
and shell scripts. You do need the macOS command line tools, which provide
`swift` and `codesign`.

## Build and run

### Install a release without a certificate

Download `GitLabAlert-0.1.4.dmg` from the
[latest GitHub release](https://github.com/AlbertoBarrago/gitlab-alert/releases/latest),
open it and drag `GitLabAlert.app` onto the Applications shortcut. You do not
need an Apple Developer account or your own signing certificate. A ZIP is also
available as a fallback.

The app is not notarized. First try to open it from Applications so macOS
records the blocked launch. Then open **System Settings → Privacy & Security**,
scroll to Security, click **Open Anyway**, authenticate and confirm **Open**.
If macOS still reports that the app cannot be opened, remove only its quarantine
attribute, then launch it again:

```sh
xattr -dr com.apple.quarantine "/Applications/GitLabAlert.app"
```

This is narrower than `xattr -cr`, which removes every extended attribute from
the bundle. Run it only after verifying that the app came from this repository's
GitHub release.

### Build from source

```sh
bash bin/make-signing-cert.sh   # once, ever
bash bin/make-app.sh            # build + install to /Applications
bash bin/run-with-logs.sh       # rebuild, relaunch, stream the logs
```

`bin/make-app.sh` runs `swift build`, assembles `/Applications/GitLabAlert.app`
around the binary, copies `Info.plist` and the resources, signs it, then verifies
the signature before it can launch.

### Why the certificate step

macOS pins **Keychain item ACLs** and **notification authorization** to the
app's code-signing designated requirement. Ad-hoc signing (`codesign --sign -`)
has no certificate, so that requirement falls back to the binary's cdhash,
which changes on every build. The app then stops recognising the token it stored
itself, and the notification grant resets.

`bin/make-signing-cert.sh` generates a self-signed code-signing certificate once
and imports it into your login keychain. It costs nothing, needs no Apple
account, and keeps the requirement stable across rebuilds. Keep
`bin/.signing/` backed up. Losing it means a new identity, so you will need to
paste the token and grant notifications once more.

The build scripts select an identity in this order: this project's certificate,
then an Apple Development certificate that actually verifies, then ad-hoc with a
loud warning. `security find-identity -v` can report revoked certificates as
valid from a stale OCSP cache, so the scripts validate candidates by signing a
scratch binary and running `codesign --verify --strict`.

The app is **not notarized**, which requires a paid Developer ID. Building from
source avoids the first-launch Gatekeeper step. The signing certificate is
optional for a single local build, but recommended for repeated builds so
Keychain and notification permissions remain stable.

## Configuration

GitLab Alert authenticates with a personal access token. In Settings, enter the
origin of GitLab.com or of your self-managed instance, for example
`https://gitlab.com` or `https://gitlab.example.com`. Origin changes take effect
immediately.

Create a token at the configured instance's
`/-/user_settings/personal_access_tokens` page and grant only this scope:

| Scope | Why |
| --- | --- |
| `read_api` | profile, merge requests, issues, projects and pipeline status |

No write scope is needed or requested. The token is stored in the macOS
Keychain for that Mac only, is never written to disk in plaintext, never shown
again after saving, and is sent only to the configured GitLab instance.

The default repository scope includes projects you are a member of that were
active in the past 90 days, excluding forks. The Repositories pane lets you
search the catalogue and explicitly include or exclude individual projects.

GitLab instances hosted below a URL sub-path are not supported yet.

## How it works

Each refresh fetches your profile, open merge requests where you are an assignee,
reviewer or author, issues assigned to you, and the member projects in scope. The latest
pipeline is then fetched for each watched project. List endpoints are fully
paginated and pipeline checks are concurrency-limited. Both the page size and
the pipeline concurrency can be adjusted in Settings for self-managed GitLab
instances.

The app stores credentials in the Keychain, preferences in `UserDefaults`, and
the last dashboard plus notification watermarks in Application Support. The
first successful refresh seeds those watermarks silently, so a new installation
does not notify you about pre-existing work or failed pipelines.

The implementation uses GitLab REST API v4. The full design is in
[`docs/architecture.md`](docs/architecture.md).

## Tests

The REST client, models, persistence, polling support and diffing live in
`GitLabKit/`, a local SwiftPM package with no UI dependency:

```sh
bash bin/test.sh          # GitLabKit + app lifecycle regression tests
```

The test suites cover API mapping, Keychain error handling through test stores,
concurrent refreshes, cancellation, account replacement, notification routing,
and persisted read state. The menu bar UI still needs manual verification; see
[`docs/manual-qa.md`](docs/manual-qa.md).

## Layout

```
GitLabAlert/         app sources: AppKit shell, SwiftUI views, settings
GitLabKit/           local SwiftPM package: REST client and testable logic
bin/                 build, run, release and signing scripts
docs/                architecture and manual QA checklist
Info.plist           copied into the bundle by the build script
Resources/           loose resources, read through Bundle.main
```

## Release

```sh
bash bin/make-release.sh
```

This runs the tests, builds Release, assembles and signs the bundle, then writes
`dist/GitLabAlert-<version>.dmg` and `dist/GitLabAlert-<version>.zip`. It mounts
the DMG to verify its contents and the embedded app signature, and refuses to
create a release with an ad-hoc signature.

## License

MIT. See [LICENSE](LICENSE).
