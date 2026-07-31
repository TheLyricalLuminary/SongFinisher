import Testing
import Foundation
@testable import SongFinisher

/// The free tier's daily budget is revenue-critical and had no coverage. It matters more
/// now that `ProStore.allowPremiumGeneration()` short-circuits in DEBUG: that bypass means
/// the metered path is no longer exercised by simply running the app during development,
/// so the budget logic is pinned directly here instead.
///
/// Each test gets its own `UserDefaults` suite — the real one persists across runs, and a
/// leaked counter would make these pass or fail depending on what you did yesterday.
@Suite @MainActor struct GenerationAllowanceTests {

    private func isolatedDefaults() -> UserDefaults {
        UserDefaults(suiteName: "GenerationAllowanceTests.\(UUID().uuidString)")!
    }

    private var yesterday: TimeInterval {
        Calendar.current.startOfDay(for: Date().addingTimeInterval(-86_400)).timeIntervalSinceReferenceDate
    }

    @Test func spendsExactlyTheDailyBudgetThenRefuses() {
        let allowance = GenerationAllowance(defaults: isolatedDefaults())
        for _ in 0..<GenerationAllowance.freePerDay {
            #expect(allowance.consume())
        }
        #expect(allowance.consume() == false)
        #expect(allowance.remainingToday == 0)
    }

    @Test func refusingDoesNotKeepCountingPastTheBudget() {
        // `consume()` returns false without incrementing, so a user who keeps tapping
        // doesn't dig a hole that survives into tomorrow.
        let allowance = GenerationAllowance(defaults: isolatedDefaults())
        for _ in 0..<(GenerationAllowance.freePerDay + 5) { _ = allowance.consume() }
        #expect(allowance.usedToday == GenerationAllowance.freePerDay)
    }

    @Test func budgetResetsOnANewDay() {
        let defaults = isolatedDefaults()
        let allowance = GenerationAllowance(defaults: defaults)
        for _ in 0..<GenerationAllowance.freePerDay { _ = allowance.consume() }
        #expect(allowance.consume() == false)

        defaults.set(yesterday, forKey: "generationAllowance.day")

        #expect(allowance.consume())
        #expect(allowance.usedToday == 1)
    }

    @Test func todaysSpendSurvivesRelaunch() {
        // A new instance is what happens on app launch; the count has to come back from
        // disk or the daily budget is trivially resettable by force-quitting.
        let defaults = isolatedDefaults()
        let firstLaunch = GenerationAllowance(defaults: defaults)
        _ = firstLaunch.consume()
        _ = firstLaunch.consume()

        let relaunched = GenerationAllowance(defaults: defaults)
        #expect(relaunched.usedToday == 2)
        #expect(relaunched.remainingToday == GenerationAllowance.freePerDay - 2)
    }

    @Test func aStaleCountFromAnEarlierDayIsIgnoredAtLaunch() {
        let defaults = isolatedDefaults()
        defaults.set(yesterday, forKey: "generationAllowance.day")
        defaults.set(GenerationAllowance.freePerDay, forKey: "generationAllowance.count")

        let allowance = GenerationAllowance(defaults: defaults)

        #expect(allowance.usedToday == 0)
        #expect(allowance.remainingToday == GenerationAllowance.freePerDay)
    }
}
