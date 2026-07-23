import Testing
@testable import LyricEngine

struct TemplateBankTests {

    /// Regression for "she provision the sheer whip": the lexicon's verb bucket
    /// serves base forms, so a third-person-singular subject must never sit
    /// immediately before an open verb slot in any template.
    @Test func thirdPersonSingularSubjectsNeverPrecedeABareVerbSlot() {
        for template in TemplateBank.all {
            for (i, slot) in template.slots.enumerated() {
                guard case .oneOf(let words) = slot,
                      words.contains("she") || words.contains("he"),
                      i + 1 < template.slots.count,
                      case .pos(let next) = template.slots[i + 1] else { continue }
                #expect(!next.contains(.verb),
                        "template pairs she/he with a bare verb slot: \(words)")
            }
        }
    }

    /// Regression for "you was readily legion": wherever a subject literal set is
    /// followed by a copula literal set, every subject in the set must agree with
    /// every copula in the set.
    @Test func subjectAndCopulaLiteralsAlwaysAgree() {
        let copulas: Set<String> = ["am", "is", "are", "was", "were"]
        let agreement: [String: Set<String>] = [
            "I": ["am", "was"],
            "you": ["are", "were"], "we": ["are", "were"], "they": ["are", "were"],
            "she": ["is", "was"], "he": ["is", "was"], "it": ["is", "was"],
        ]
        for template in TemplateBank.all {
            for (i, slot) in template.slots.enumerated() {
                guard case .oneOf(let subjects) = slot,
                      i + 1 < template.slots.count,
                      case .oneOf(let verbs) = template.slots[i + 1],
                      verbs.allSatisfy({ copulas.contains($0) }) else { continue }
                for subject in subjects {
                    guard let allowed = agreement[subject] else { continue }
                    for verb in verbs {
                        #expect(allowed.contains(verb),
                                "template pairs '\(subject)' with '\(verb)'")
                    }
                }
            }
        }
    }
}
