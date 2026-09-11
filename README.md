# GitLab Alert

GitLab Alert is a macOS menu bar app for GitLab.com and self-managed GitLab
instances. It shows merge requests awaiting review, authored merge requests,
assigned issues, and recently active projects without keeping a browser tab open.

## Current scope

The first usable slice uses GitLab REST API v4 and supports:

- a configurable HTTPS GitLab instance origin;
- personal access tokens stored in the macOS Keychain;
- profile verification;
- open merge requests where you are reviewer or author;
- open issues assigned to you;
- projects where you are a member.

Project star and fork counters are displayed when GitLab returns them. GitLab's
REST API does not expose reliable starrer attribution, so the app deliberately
does not claim to notify who starred a project. Pipeline health is not yet part
of the dashboard.

## Configuration

In Settings, enter the origin of your GitLab instance, for example
`https://gitlab.com` or `https://gitlab.example.com`, then restart the app.
Create a personal access token with the `read_api` scope and paste it into the
account pane. The token is stored only in the Keychain.

GitLab installations hosted below a URL sub-path are not supported yet.

## Build and test

```sh
bash bin/make-signing-cert.sh
bash bin/make-app.sh

swift test --package-path GitLabKit
swift test
```

The app requires macOS 14 and Swift 6. `GitLabKit` contains the REST client,
models, polling support, persistence and diffing. `GitLabAlert` contains the
AppKit shell and SwiftUI surfaces.
