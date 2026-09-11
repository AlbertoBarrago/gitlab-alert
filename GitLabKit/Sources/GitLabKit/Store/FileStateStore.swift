import Darwin
import Foundation
import os.log

/// Why a save could not be completed. `load()` never fails by contract, so
/// every case here belongs to the write path.
public enum StateStoreError: Error, Sendable, Equatable {
    case encodingFailed(String)
    case directoryCreationFailed(String)
    case temporaryWriteFailed(String)
    /// The atomic rename of the temp file over `state.json` failed.
    case replaceFailed(errno: Int32, message: String)
}

/// ``PersistedState`` as a JSON file, by default at
/// `~/Library/Application Support/GitLabAlert/state.json`.
///
/// A `Sendable` struct rather than an actor: `StateStore` is a synchronous
/// protocol, and an actor cannot satisfy synchronous requirements. There is no
/// shared mutable state here — the only instance storage is the file URL — and
/// non-interleaving is a property of the write itself, not of a lock: every
/// save encodes into a uniquely named sibling temp file and then `rename(2)`s
/// it over the destination. `rename` within one filesystem is atomic, so a
/// reader sees either the whole previous file or the whole new one, and two
/// concurrent saves resolve to last-writer-wins instead of a torn file.
public struct FileStateStore: StateStore {
    /// Newest events to keep. The activity log is a rolling feed the user
    /// glances at, not an archive: unbounded growth would make every save
    /// rewrite an ever larger file and every launch decode it. Capping in the
    /// store (rather than at the call site) means no caller can forget to.
    public static let maxActivityLogEntries = 200

    /// Hard ceiling on remembered "seen" ids. They must outlive the events
    /// still in the log — the diff engine also records ids of events it chose
    /// not to log, and dropping those would re-notify — so this cap is larger
    /// than the log and prefers ids the log still references.
    public static let maxSeenEventIDs = 1_000

    public let fileURL: URL
    private let log = Logger(subsystem: "com.alBz.GitLabAlert", category: "StateStore")

    public init(fileURL: URL = FileStateStore.defaultFileURL()) {
        self.fileURL = fileURL
    }

    public static func defaultFileURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
                .appendingPathComponent("Library/Application Support", isDirectory: true)
        return base
            .appendingPathComponent("GitLabAlert", isDirectory: true)
            .appendingPathComponent("state.json", isDirectory: false)
    }

    // MARK: - Load

    /// Never throws and never crashes. Any unreadable, unparseable or
    /// unrecognised file is treated as "no state yet": a fresh
    /// ``PersistedState`` with `hasBaseline` false, which makes the next poll
    /// re-seed silently instead of notifying about every open item at once.
    public func load() -> PersistedState {
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch {
            log.debug("No readable state file at \(self.fileURL.path, privacy: .public); starting fresh.")
            return PersistedState()
        }

        guard !data.isEmpty else {
            log.debug("State file is empty; starting fresh.")
            return PersistedState()
        }

        let state: PersistedState
        do {
            state = try Self.makeDecoder().decode(PersistedState.self, from: data)
        } catch {
            log.debug("State file is corrupt or has an unexpected shape (\(String(describing: error), privacy: .public)); starting fresh.")
            return PersistedState()
        }

        guard state.version == PersistedState.currentVersion else {
            // A newer version means a downgrade: its fields may be missing or
            // mean something else. An older one has no migration path yet.
            // Either way, discarding beats guessing.
            log.debug("State file version \(state.version) is not \(PersistedState.currentVersion); starting fresh.")
            return PersistedState()
        }

        return state
    }

    // MARK: - Save

    public func save(_ state: PersistedState) throws {
        // Encode first: a failure here must leave the existing file untouched,
        // so nothing is created or replaced before the bytes exist.
        let data: Data
        do {
            data = try Self.makeEncoder().encode(Self.capped(state))
        } catch {
            throw StateStoreError.encodingFailed(String(describing: error))
        }

        let directory = fileURL.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: NSNumber(value: 0o700)]
            )
        } catch {
            throw StateStoreError.directoryCreationFailed(String(describing: error))
        }

        let temporaryURL = directory.appendingPathComponent(
            "\(fileURL.lastPathComponent).\(UUID().uuidString).tmp",
            isDirectory: false
        )
        do {
            try data.write(to: temporaryURL, options: [.atomic])
            // Tighten the mode on the temp file, before it becomes visible
            // under the real name: the state file holds the user's activity,
            // and there is no window in which it is group/world readable.
            try FileManager.default.setAttributes(
                [.posixPermissions: NSNumber(value: 0o600)],
                ofItemAtPath: temporaryURL.path
            )
        } catch {
            try? FileManager.default.removeItem(at: temporaryURL)
            throw StateStoreError.temporaryWriteFailed(String(describing: error))
        }

        guard rename(temporaryURL.path, fileURL.path) == 0 else {
            let code = errno
            try? FileManager.default.removeItem(at: temporaryURL)
            throw StateStoreError.replaceFailed(errno: code, message: String(cString: strerror(code)))
        }
    }

    // MARK: - Capping

    /// Trims the unbounded collections to their caps. `internal` so the tests
    /// can assert on the rule directly as well as through a round-trip.
    static func capped(_ state: PersistedState) -> PersistedState {
        var capped = state

        // The log is documented as newest-first; sort rather than trust the
        // caller, and break ties on id so the file is deterministic.
        let ordered = state.activityLog.sorted {
            $0.occurredAt == $1.occurredAt ? $0.id > $1.id : $0.occurredAt > $1.occurredAt
        }
        capped.activityLog = Array(ordered.prefix(maxActivityLogEntries))

        if state.seenEventIDs.count > maxSeenEventIDs {
            let retained = Set(capped.activityLog.map(\.id))
            let keep = state.seenEventIDs.intersection(retained)
            let filler = state.seenEventIDs.subtracting(keep).sorted()
            capped.seenEventIDs = keep.union(filler.prefix(maxSeenEventIDs - keep.count))
        }

        return capped
    }

    // MARK: - Coding

    /// Default date strategy on purpose: it encodes a `Date` as its
    /// `timeIntervalSinceReferenceDate`, which round-trips bit-exactly.
    /// ISO-8601 would silently drop sub-second precision and make watermark
    /// comparisons (`>` on timestamps) go wrong by up to a second.
    private static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    private static func makeDecoder() -> JSONDecoder {
        JSONDecoder()
    }
}
