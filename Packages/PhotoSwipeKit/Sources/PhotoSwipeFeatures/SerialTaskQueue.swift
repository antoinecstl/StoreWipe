import Foundation

/// File d'opérations asynchrones exécutées strictement dans l'ordre d'envoi.
///
/// Les décisions sont appliquées à l'interface immédiatement (optimiste), puis persistées
/// via cette file : une annulation ou un rechargement de pile ne peut donc jamais doubler
/// une écriture encore en attente.
@MainActor
final class SerialTaskQueue {
    private var tail: Task<Void, Never>?

    func enqueue(_ operation: @escaping @MainActor @Sendable () async -> Void) {
        let previous = tail
        tail = Task { @MainActor in
            await previous?.value
            await operation()
        }
    }

    /// Attend la fin de toutes les opérations envoyées, y compris celles ajoutées pendant l'attente.
    func drain() async {
        while let current = tail {
            await current.value
            if tail == current {
                tail = nil
                return
            }
        }
    }
}
