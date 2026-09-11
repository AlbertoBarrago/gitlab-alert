# Architecture

GitLab Alert is split into two layers:

- `GitLabAlert`: the AppKit menu bar shell, SwiftUI views, preferences,
  notifications and polling orchestration.
- `GitLabKit`: GitLab REST API v4 client, Keychain and state stores, models,
  rate limiting and the pure activity diff engine.

Views depend on `AppModel`; no view constructs a network client. `AppDelegate`
owns the dependency graph and creates an instance-specific `GitLabClient` from
the persisted GitLab origin.

The current dashboard poll requests `/user`, open merge requests for the current
reviewer and author, assigned open issues, and member projects. These requests
are independent and run concurrently. The API client authenticates using the
`PRIVATE-TOKEN` header and maps transport, authentication, authorization and
HTTP failures to `GitLabError`.

Credentials live in the Keychain. Preferences live in `UserDefaults`. Cached
dashboard state and activity watermarks are atomically persisted in Application
Support under the GitLab Alert namespace.

The copied diff engine currently remains responsible for stable activity IDs and
baseline behavior. GitLab-specific notifications will be narrowed as pipeline
and merge-request event sources are added, rather than treating GitHub event
semantics as a permanent compatibility layer.
