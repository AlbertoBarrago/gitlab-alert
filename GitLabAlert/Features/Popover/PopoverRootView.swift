import GitLabKit
import SwiftUI

/// The popover: the surface the user sees twenty times a day.
///
/// Hosted in an `NSHostingView` inside an `NSPopover`, so it is **not** in a
/// SwiftUI scene: `@Environment(\.openWindow)` and `SettingsLink` do nothing
/// here. Every action routes through `AppModel`.
///
/// Width is fixed at `PopoverController.contentWidth`. A menu bar popover that
/// changes width as content arrives reads as broken, so only the height moves.
struct PopoverRootView: View {

    let model: AppModel

    /// Which sections are open. Session-scoped on purpose: the useful default is
    /// "whatever is actionable", not whatever the user left open yesterday.
    @State private var expanded: Set<DashboardSection> = []
    @State private var selection: String?
    @State private var didSeedExpansion = false
    @State private var onboardingHeight = PopoverController.initialHeight
    @State private var dashboardListHeight: CGFloat = 1
    @State private var dashboardHeaderHeight: CGFloat = 0
    @State private var dashboardFooterHeight: CGFloat = 44
    @FocusState private var isFocused: Bool

    private enum Phase {
        case needsToken
        case rejected(String)
        case failedCold(GitLabError)
        case loadingCold
        case dashboard
    }

    private var phase: Phase {
        switch model.authState {
        case .needsToken:
            return .needsToken
        case .rejected(let message):
            return .rejected(message)
        case .verifying, .ready:
            break
        }
        if model.snapshot != nil { return .dashboard }
        if let error = model.lastError { return .failedCold(error) }
        return .loadingCold
    }

    var body: some View {
        VStack(spacing: 0) {
            switch phase {
            case .needsToken, .rejected:
                // Reuses the Account pane's own controls rather than a second
                // token field: onboarding that drifts from Settings is how you
                // end up explaining two different sets of scopes.
                ScrollView {
                    OnboardingView(model: model)
                        .padding(14)
                        .background {
                            GeometryReader { geometry in
                                Color.clear.onChange(of: geometry.size.height, initial: true) { _, height in
                                    onboardingHeight = height
                                }
                            }
                        }
                }
                // Measure the content, not the scroll viewport: the latter
                // only reports the already constrained popover height.
                .frame(height: min(onboardingHeight, model.popoverMaximumHeight))
            case .failedCold(let error):
                CallToActionView(
                    symbolName: coldFailureSymbol(for: error),
                    title: coldFailureTitle(for: error),
                    message: error.userMessage,
                    actionTitle: "Try Again",
                    action: model.refresh
                )
            case .loadingCold:
                loadingState
            case .dashboard:
                dashboard
            }
        }
        .frame(width: PopoverController.contentWidth)
        .background(.regularMaterial)
        // Tells AppKit the height we want, so expanding a section grows the
        // panel instead of clipping. `PopoverController` clamps and animates it.
        .background(
            GeometryReader { geometry in
                Color.clear
                    .onChange(of: geometry.size.height, initial: true) { _, height in
                        model.setPopoverHeight?(height)
                    }
            }
        )
        // The popover already sits on a system material: stacking a glass
        // effect on top of it muddies both.
        .focusable()
        .focused($isFocused)
        .onAppear {
            isFocused = true
            seedExpansionIfNeeded()
        }
        .onChange(of: model.refreshTick) { _, _ in seedExpansionIfNeeded(force: false) }
        // Escape is deliberately NOT handled here. `PopoverController` installs a
        // local key monitor for it, precisely because the presence of any
        // `.onKeyPress` silently disables the popover's built-in Escape.
        .onKeyPress(phases: .down) { press in handleKey(press) }
    }

    private func coldFailureTitle(for error: GitLabError) -> String {
        switch error {
        case .http(let status, _) where status >= 500:
            return "GitLab is unavailable"
        case .rateLimited:
            return "Rate limit reached"
        case .forbidden:
            return "Access denied"
        default:
            return "Can't reach GitLab"
        }
    }

    private func coldFailureSymbol(for error: GitLabError) -> String {
        switch error {
        case .http(let status, _) where status >= 500:
            return "server.rack"
        case .rateLimited:
            return "clock.badge.exclamationmark"
        case .forbidden:
            return "lock.trianglebadge.exclamationmark"
        default:
            return "wifi.exclamationmark"
        }
    }

    // MARK: - Dashboard

    private var dashboard: some View {
        VStack(spacing: 0) {
            if model.showProfileHeader, let profile = model.profile {
                VStack(spacing: 0) {
                    ProfileHeaderView(profile: profile) {
                        model.openOnGitLab(profile.url)
                    }
                    Divider().opacity(0.5)
                }
                .background {
                    heightReader { dashboardHeaderHeight = $0 }
                }
            }

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        if isEverythingQuiet {
                            EmptyStateView(
                                symbolName: "checkmark.circle",
                                message: "Nothing waiting on you",
                                style: .inline
                            )
                            .frame(maxWidth: .infinity)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 3)
                        }

                        ForEach(model.sections) { section in
                            sectionBlock(section)
                        }
                    }
                    .padding(.vertical, 6)
                    .background {
                        heightReader { dashboardListHeight = $0 }
                    }
                }
                .onChange(of: selection) { _, new in
                    guard let new else { return }
                    withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(new, anchor: .center) }
                }
            }
            .frame(height: min(dashboardListHeight, dashboardListMaximumHeight))

            VStack(spacing: 0) {
                Divider().opacity(0.5)
                PopoverFooterView(model: model)
            }
            .background {
                heightReader { dashboardFooterHeight = $0 }
            }
        }
        .onChange(of: model.showProfileHeader) { _, isVisible in
            if !isVisible { dashboardHeaderHeight = 0 }
        }
    }

    private var dashboardListMaximumHeight: CGFloat {
        max(80, model.popoverMaximumHeight - dashboardHeaderHeight - dashboardFooterHeight)
    }

    private func heightReader(onChange: @escaping (CGFloat) -> Void) -> some View {
        GeometryReader { geometry in
            Color.clear.onChange(of: geometry.size.height, initial: true) { _, height in
                onChange(height)
            }
        }
    }

    /// True when every visible section is empty — the state the user is in most
    /// of the time, and therefore the one that has to look intentional.
    private var isEverythingQuiet: Bool {
        model.sections.allSatisfy { model.count(for: $0) == 0 }
    }

    @ViewBuilder
    private func sectionBlock(_ section: DashboardSection) -> some View {
        let count = model.count(for: section)
        let isExpanded = expanded.contains(section)

        SectionRowView(
            section: section,
            count: count,
            isExpanded: isExpanded,
            isSelected: selection == section.id,
            isMuted: count == 0,
            toggle: { toggle(section) }
        )
        .id(section.id)

        if isExpanded {
            if count == 0 {
                EmptyStateView(
                    symbolName: section.symbolName,
                    message: emptyMessage(for: section),
                    style: .inline
                )
                .padding(.leading, 24)
                .padding(.vertical, 2)
            } else {
                sectionContent(section)

                if count > visibleLimit {
                    SeeAllButton(remaining: count - visibleLimit) {
                        model.openDetail(section: section)
                    }
                    .padding(.leading, 24)
                }
            }
        }
    }

    /// How many rows a section shows inline before deferring to the detail
    /// window. Five keeps the popover a glance rather than a list.
    private let visibleLimit = 5

    @ViewBuilder
    private func sectionContent(_ section: DashboardSection) -> some View {
        switch section {
        case .activity:
            ForEach(Array(model.activityLog.prefix(visibleLimit))) { event in
                ActivityRowView(
                    event: event,
                    isUnread: model.unreadEventIDs.contains(event.id),
                    isSelected: selection == event.id
                ) {
                    model.openOnGitLab(event.url)
                }
                .id(event.id)
            }
        default:
            ForEach(items(for: section)) { item in
                WorkItemRowView(item: item, isSelected: selection == item.id) {
                    model.openOnGitLab(item.url)
                }
                .id(item.id)
            }
        }
    }

    private func items(for section: DashboardSection) -> [WorkItemRowView.Item] {
        let all: [WorkItemRowView.Item]
        switch section {
        case .reviewRequested:
            all = model.reviewRequested.map(WorkItemRowView.Item.init(mergeRequest:))
        case .authoredMergeRequests:
            all = model.authoredMergeRequests.map(WorkItemRowView.Item.init(mergeRequest:))
        case .assignedIssues:
            all = model.assignedIssues.map(WorkItemRowView.Item.init(issue:))
        case .inboundIssues:
            all = model.inboundIssues.map(WorkItemRowView.Item.init(issue:))
        case .repositories:
            all = model.brokenRepositories.map(WorkItemRowView.Item.init(repository:))
        case .activity:
            all = []
        }
        return Array(all.prefix(visibleLimit))
    }

    private func emptyMessage(for section: DashboardSection) -> String {
        switch section {
        case .reviewRequested: return "No reviews waiting on you"
        case .authoredMergeRequests: return "No open merge requests of yours"
        case .assignedIssues: return "Nothing assigned to you"
        case .inboundIssues: return "No inbound issues"
        case .repositories: return "All checks are green"
        case .activity: return "No new stars or forks yet"
        }
    }

    private var loadingState: some View {
        VStack(spacing: 10) {
            ProgressView().controlSize(.small)
            Text("Loading your GitLab…")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 48)
        .accessibilityLabel("Loading your GitLab status")
    }

    // MARK: - Expansion

    /// Opens whatever is actionable on first sight, so the popover answers the
    /// question without a click. Only seeds once per launch: after that the
    /// user's own expand/collapse choices win.
    private func seedExpansionIfNeeded(force: Bool = true) {
        guard !didSeedExpansion else { return }
        guard model.snapshot != nil || force == false else { return }
        guard model.snapshot != nil else { return }

        didSeedExpansion = true
        var opened = Set<DashboardSection>()
        for section in model.sections where model.count(for: section) > 0 {
            opened.insert(section)
            if opened.count == 2 { break }
        }
        expanded = opened
        if opened.contains(.activity) { model.markActivitySeen() }
    }

    private func toggle(_ section: DashboardSection) {
        withAnimation(.spring(response: 0.28, dampingFraction: 0.86)) {
            if expanded.contains(section) {
                expanded.remove(section)
            } else {
                expanded.insert(section)
                if section == .activity { model.markActivitySeen() }
            }
        }
        selection = section.id
    }

    // MARK: - Keyboard

    /// Every row and section header, in the order they appear on screen, so
    /// ↑/↓ walk what the user can actually see.
    private var navigableIDs: [String] {
        var ids: [String] = []
        for section in model.sections {
            ids.append(section.id)
            guard expanded.contains(section) else { continue }
            if section == .activity {
                ids.append(contentsOf: model.activityLog.prefix(visibleLimit).map(\.id))
            } else {
                ids.append(contentsOf: items(for: section).map(\.id))
            }
        }
        return ids
    }

    private func handleKey(_ press: KeyPress) -> KeyPress.Result {
        if press.modifiers.contains(.command) {
            switch press.characters {
            case "r":
                model.refresh()
                return .handled
            case ",":
                model.openSettings()
                return .handled
            default:
                return .ignored
            }
        }

        switch press.key {
        case .upArrow:
            move(by: -1)
            return .handled
        case .downArrow:
            move(by: 1)
            return .handled
        case .return:
            activateSelection()
            return .handled
        default:
            return .ignored
        }
    }

    private func move(by offset: Int) {
        let ids = navigableIDs
        guard !ids.isEmpty else { return }
        guard let current = selection, let index = ids.firstIndex(of: current) else {
            selection = offset > 0 ? ids.first : ids.last
            return
        }
        let next = index + offset
        guard next >= 0 && next < ids.count else { return }
        selection = ids[next]
    }

    /// Return either expands a section header or opens an item — whichever the
    /// selection currently is.
    private func activateSelection() {
        guard let selection else { return }

        if let section = DashboardSection(rawValue: selection) {
            toggle(section)
            return
        }
        if let event = model.activityLog.first(where: { $0.id == selection }) {
            model.openOnGitLab(event.url)
            return
        }
        for section in model.sections {
            if let item = items(for: section).first(where: { $0.id == selection }) {
                model.openOnGitLab(item.url)
                return
            }
        }
    }
}

// MARK: - Pieces used only by the root

/// The full-panel states: no token, rejected token, cold failure. Deliberately
/// one shape for all three so they feel like states of the same app rather than
/// three different error screens.
private struct CallToActionView: View {
    let symbolName: String
    let title: String
    let message: String
    let actionTitle: String
    let action: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: symbolName)
                .font(.system(size: 26, weight: .light))
                .foregroundStyle(.tertiary)
            Text(title)
                .font(.headline)
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Button(actionTitle, action: action)
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
                .padding(.top, 2)
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 34)
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(title). \(message)")
    }
}

private struct SeeAllButton: View {
    let remaining: Int
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Text("See all")
                Text("+\(remaining)")
                    .monospacedDigit()
                    .foregroundStyle(.tertiary)
                Image(systemName: "arrow.up.forward.square")
                    .font(.caption2)
            }
            .font(.caption)
            .foregroundStyle(isHovering ? Color.accentColor : .secondary)
            .padding(.vertical, 3)
            .padding(.horizontal, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .accessibilityLabel("See all, \(remaining) more, opens the GitLab Alert window")
    }
}

// MARK: - Previews

#Preview("Populated") {
    PopoverRootView(model: SampleData.populatedModel)
}

#Preview("Resting") {
    PopoverRootView(model: SampleData.restingModel)
}

#Preview("Needs token") {
    PopoverRootView(model: SampleData.needsTokenModel)
}

#Preview("Offline with stale data") {
    PopoverRootView(model: SampleData.staleModel)
}

#Preview("Cold failure") {
    PopoverRootView(model: SampleData.failedModel)
}
