import Foundation
import Observation
import PhotoSwipeCore
import PhotoSwipeStore

public enum SortingSessionIssue: Sendable, Equatable {
    case loadFailed
    case saveFailed
    case undoUnavailable
}

/// Entrée de la pile d'annulation. `eventID` est renseigné dès que l'écriture est validée.
@MainActor
final class UndoEntry {
    let item: QueueItem
    /// Décision enregistrée ; `nil` si l'action n'a rien changé (photo passée pendant une revue).
    let target: Decision?
    var eventID: Int64?
    var isUndone = false

    init(item: QueueItem, target: Decision?, eventID: Int64? = nil) {
        self.item = item
        self.target = target
        self.eventID = eventID
    }
}

/// Moteur d'une session de tri : pile de photos, décisions, annulation et reprise.
///
/// Les actions mettent l'interface à jour immédiatement ; la persistance suit dans une
/// file sérielle. Aucune action de ce modèle ne supprime de photo de la photothèque.
@MainActor
@Observable
public final class SortingSessionModel {
    public enum State: Sendable, Equatable {
        case loading
        case sorting
        /// Plus aucune photo à présenter dans le périmètre de la session.
        case completed
        case failed
    }

    public private(set) var state: State = .loading
    public private(set) var session: SortingSessionRecord
    public private(set) var stats: SessionStats = .zero
    public private(set) var remainingCount = 0
    public var issue: SortingSessionIssue?
    /// Photo courante suivie des photos préchargées.
    public private(set) var buffer: [QueueItem] = []
    private var undoStack: [UndoEntry] = []

    public var current: QueueItem? { buffer.first }
    public var upcoming: ArraySlice<QueueItem> { buffer.dropFirst() }
    public var canUndo: Bool { !undoStack.isEmpty }
    public var scope: SessionScope { session.scope }
    /// Vrai si la pile se recharge alors qu'aucune photo n'est prête.
    public var isWaitingForItems: Bool { state == .sorting && buffer.isEmpty }

    public static let pageSize = 12
    public static let lowWaterMark = 5
    public static let undoLimit = 50

    private let store: PhotoSwipeStore
    private let now: @Sendable () -> Date
    @ObservationIgnored private let operations = SerialTaskQueue()
    @ObservationIgnored private var phaseIndex = 0
    @ObservationIgnored private var mainCursor: SortKey?
    @ObservationIgnored private var hasWrappedMain = false
    @ObservationIgnored private var keptCursor: SortKey?
    @ObservationIgnored private var keptCursorInclusive = true
    @ObservationIgnored private var phasesExhausted = false
    @ObservationIgnored private var hasStarted = false
    @ObservationIgnored private var unavailableIDs: Set<AssetID> = []
    /// Photos dont l'écriture est encore en attente : exclues des rechargements de pile
    /// pour ne jamais être présentées deux fois.
    @ObservationIgnored private var pendingWrites: [AssetID: Int] = [:]

    public init(store: PhotoSwipeStore, session: SortingSessionRecord, now: @escaping @Sendable () -> Date = { Date() }) {
        self.store = store
        self.session = session
        self.now = now
        self.mainCursor = session.cursor
        self.keptCursor = session.cursor
    }

    // MARK: - Cycle de vie

    /// Charge les compteurs, la pile d'annulation persistée et la première page.
    public func start() async {
        guard !hasStarted else { return }
        hasStarted = true
        operations.enqueue { [weak self] in
            guard let self else { return }
            do {
                let sessionID = self.session.id
                self.stats = try await self.store.sessionStats(sessionID)
                self.remainingCount = try await self.store.remainingCount(for: self.session)
                let events = try await self.store.undoableEvents(sessionID: sessionID, limit: Self.undoLimit)
                self.undoStack = events.reversed().map { pair in
                    UndoEntry(
                        item: QueueItem(
                            asset: pair.asset,
                            decision: pair.event.previousDecision,
                            decidedAt: pair.event.previousDecidedAt,
                            phase: Self.phase(forPreviousDecision: pair.event.previousDecision)
                        ),
                        target: pair.event.newDecision,
                        eventID: pair.event.id
                    )
                }
                await self.refill()
                self.state = self.buffer.isEmpty && self.phasesExhausted ? .completed : .sorting
            } catch {
                self.issue = .loadFailed
                self.state = .failed
            }
        }
        await operations.drain()
    }

    /// Relance la recherche de photos après une mise à jour de l'index (nouvelles photos,
    /// indexation initiale encore en cours au démarrage de la session).
    public func reloadQueue() {
        guard hasStarted, state != .failed else { return }
        operations.enqueue { [weak self] in
            guard let self else { return }
            self.phaseIndex = 0
            self.phasesExhausted = false
            await self.refill(force: true)
            if let remaining = try? await self.store.remainingCount(for: self.session) {
                self.remainingCount = remaining
            }
            self.updateCompletion()
        }
    }

    /// Attend la fin des écritures en cours (tests, sortie de l'écran).
    public func flush() async {
        await operations.drain()
    }

    // MARK: - Actions

    public func perform(_ action: SortAction) {
        guard state == .sorting, let item = buffer.first else { return }
        let target = session.scope.targetDecision(for: action)
        buffer.removeFirst()
        let entry = UndoEntry(item: item, target: target)
        undoStack.append(entry)
        if undoStack.count > Self.undoLimit {
            undoStack.removeFirst(undoStack.count - Self.undoLimit)
        }
        stats.record(target, delta: 1)
        remainingCount = max(0, remainingCount - 1)
        pendingWrites[item.id, default: 0] += 1

        let sessionID = session.id
        let date = now()
        operations.enqueue { [weak self] in
            guard let self else { return }
            if let target {
                do {
                    let event = try await self.store.applyDecision(target, to: item.id, sessionID: sessionID, at: date)
                    entry.eventID = event.id
                } catch {
                    self.rollBack(entry)
                    self.issue = .saveFailed
                }
            }
            self.completePendingWrite(for: item.id)
            await self.persistCursor()
            await self.refill()
            self.updateCompletion()
        }
    }

    /// Annule la dernière action de la session et réaffiche la photo concernée.
    public func undo() {
        guard let entry = undoStack.popLast() else { return }
        entry.isUndone = true
        buffer.removeAll { $0.id == entry.item.id }
        buffer.insert(entry.item, at: 0)
        stats.record(entry.target, delta: -1)
        remainingCount += 1
        if state == .completed {
            state = .sorting
        }
        operations.enqueue { [weak self] in
            guard let self else { return }
            if entry.target != nil, let eventID = entry.eventID {
                do {
                    if try await self.store.undo(eventID: eventID) == .stale {
                        await self.discardStaleUndo(of: entry)
                    }
                } catch {
                    self.issue = .saveFailed
                }
            }
            await self.persistCursor()
        }
    }

    /// Retire la photo courante sans décision, par exemple si elle a été supprimée
    /// entre-temps dans Photos ou n'est plus autorisée.
    public func dropUnavailableCurrent() {
        guard let item = buffer.first else { return }
        buffer.removeFirst()
        unavailableIDs.insert(item.id)
        remainingCount = max(0, remainingCount - 1)
        operations.enqueue { [weak self] in
            guard let self else { return }
            await self.persistCursor()
            await self.refill()
            self.updateCompletion()
        }
    }

    // MARK: - Pile

    private func refill(force: Bool = false) async {
        guard !phasesExhausted, force || buffer.count < Self.lowWaterMark else { return }
        let phases = session.scope.phases
        do {
            while buffer.count < Self.pageSize, phaseIndex < phases.count {
                let phase = phases[phaseIndex]
                let wanted = Self.pageSize - buffer.count
                var request = QueueRequest(
                    filter: session.scope.filter,
                    phase: phase,
                    sessionID: session.id,
                    excluding: buffer.map(\.id) + unavailableIDs + pendingWrites.keys,
                    limit: wanted
                )
                switch phase {
                case .main:
                    request.cursor = mainCursor
                    request.cursorInclusive = true
                case .kept:
                    request.cursor = keptCursor
                    request.cursorInclusive = keptCursorInclusive
                case .deferred:
                    break
                }
                let page = try await store.queuePage(request)
                let present = Set(buffer.map(\.id))
                buffer.append(contentsOf: page.filter { !present.contains($0.id) })
                if phase == .kept, let last = page.last {
                    keptCursor = last.asset.sortKey
                    keptCursorInclusive = false
                }
                if page.count < wanted {
                    if phase == .main, mainCursor != nil, !hasWrappedMain {
                        // Reprise : présenter ensuite les photos plus récentes que le point de reprise.
                        hasWrappedMain = true
                        mainCursor = nil
                    } else {
                        phaseIndex += 1
                    }
                }
            }
            if phaseIndex >= phases.count {
                phasesExhausted = true
            }
        } catch {
            issue = .loadFailed
        }
    }

    private func completePendingWrite(for id: AssetID) {
        guard let count = pendingWrites[id] else { return }
        pendingWrites[id] = count > 1 ? count - 1 : nil
    }

    private func updateCompletion() {
        if buffer.isEmpty, phasesExhausted, state == .sorting {
            state = .completed
        } else if !buffer.isEmpty, state == .completed {
            state = .sorting
        }
    }

    private func persistCursor() async {
        guard let item = buffer.first, item.phase != .deferred else { return }
        let key = item.asset.sortKey
        guard key != session.cursor else { return }
        do {
            try await store.updateCursor(sessionID: session.id, cursor: key)
            session.cursor = key
        } catch {
            // Non bloquant : sans curseur, la reprise repart de la photo non triée la plus récente.
        }
    }

    private func rollBack(_ entry: UndoEntry) {
        guard !entry.isUndone else { return }
        undoStack.removeAll { $0 === entry }
        if !buffer.contains(where: { $0.id == entry.item.id }) {
            buffer.insert(entry.item, at: 0)
        }
        stats.record(entry.target, delta: -1)
        remainingCount += 1
        if state == .completed {
            state = .sorting
        }
    }

    private func discardStaleUndo(of entry: UndoEntry) async {
        buffer.removeAll { $0.id == entry.item.id }
        issue = .undoUnavailable
        let reviewedWithoutChange = stats.reviewedWithoutChange
        if var refreshed = try? await store.sessionStats(session.id) {
            refreshed.reviewedWithoutChange = reviewedWithoutChange
            stats = refreshed
        }
        if let remaining = try? await store.remainingCount(for: session) {
            remainingCount = remaining
        }
        await refill()
        updateCompletion()
    }

    private static func phase(forPreviousDecision decision: Decision) -> QueuePhase {
        switch decision {
        case .deferred: .deferred
        case .kept: .kept
        case .unreviewed, .markedForDeletion: .main
        }
    }
}

/// Ouverture des sessions : reprise de la session active si son périmètre correspond et
/// qu'il reste des photos, sinon nouvelle session.
@MainActor
public enum SessionLauncher {
    public static func open(
        scope: SessionScope,
        store: PhotoSwipeStore,
        now: @escaping @Sendable () -> Date = { Date() }
    ) async throws -> SortingSessionModel {
        let session: SortingSessionRecord
        if let active = try await store.activeSession(),
           active.scope == scope,
           try await store.remainingCount(for: active) > 0 {
            session = active
        } else {
            session = try await store.startSession(scope: scope, at: now())
        }
        let model = SortingSessionModel(store: store, session: session, now: now)
        await model.start()
        return model
    }

    /// Reprend la session active, quel que soit son périmètre.
    public static func resumeActive(
        store: PhotoSwipeStore,
        now: @escaping @Sendable () -> Date = { Date() }
    ) async throws -> SortingSessionModel? {
        guard let active = try await store.activeSession() else { return nil }
        let model = SortingSessionModel(store: store, session: active, now: now)
        await model.start()
        return model
    }
}
