import Foundation

/// The free tier's daily budget of premium (on-device AI) generations. Offline drafts are
/// never metered — running out of allowance degrades to `AppServices.offlineLyrics`, the
/// same honest-degradation contract the rest of the pipeline follows, and the card badge
/// flips to OFFLINE DRAFT so the user always knows which engine wrote the line.
@MainActor
@Observable
final class GenerationAllowance {
    static let freePerDay = 3

    private static let dayKey = "generationAllowance.day"
    private static let countKey = "generationAllowance.count"

    private let defaults: UserDefaults
    private(set) var usedToday: Int

    var remainingToday: Int { max(0, Self.freePerDay - usedToday) }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let storedDay = defaults.double(forKey: Self.dayKey)
        let today = Calendar.current.startOfDay(for: Date()).timeIntervalSinceReferenceDate
        usedToday = storedDay == today ? defaults.integer(forKey: Self.countKey) : 0
    }

    /// Counts one premium generation against today's budget. Returns false (without
    /// counting) once the budget is spent.
    func consume() -> Bool {
        rollDayIfNeeded()
        guard usedToday < Self.freePerDay else { return false }
        usedToday += 1
        persist()
        return true
    }

    private func rollDayIfNeeded() {
        let today = Calendar.current.startOfDay(for: Date()).timeIntervalSinceReferenceDate
        if defaults.double(forKey: Self.dayKey) != today {
            usedToday = 0
            defaults.set(today, forKey: Self.dayKey)
            defaults.set(0, forKey: Self.countKey)
        }
    }

    private func persist() {
        let today = Calendar.current.startOfDay(for: Date()).timeIntervalSinceReferenceDate
        defaults.set(today, forKey: Self.dayKey)
        defaults.set(usedToday, forKey: Self.countKey)
    }
}
