import XCTest
@testable import BCIWorkspace

/// Brief 007 PR 5 (decision #46): the "?" copy follows the brief's rules.
final class HelpTopicsTests: XCTestCase {
    /// Sentences end in ".", "!" or "?" followed by a space or the end ("0.6" doesn't split).
    private func sentenceCount(_ text: String) -> Int {
        text.matches(of: /[.!?](\s|$)/).count
    }

    func testEveryTopic_isTwoToFourPlainSentences() {
        for topic in HelpTopic.allCases {
            let n = sentenceCount(topic.text)
            XCTAssertTrue((2...4).contains(n), "\(topic): \(n) sentences")
            XCTAssertFalse(topic.title.isEmpty)
            XCTAssertEqual(topic.accessibilityLabel, "Help: \(topic.title)")
            XCTAssertFalse(topic.text.contains("  "))
        }
    }

    func testTheBriefsSpotsExactly() {
        XCTAssertEqual(HelpTopic.allCases.count, 13)
        XCTAssertEqual(HelpTopic.streamHealth.accessibilityLabel, "Help: Stream health")
    }

    func testConfidence_isTheModelsOwnUncalibratedEstimate() {
        for topic in HelpTopic.allCases {
            XCTAssertFalse(topic.text.lowercased().contains("classifier confidence"), "\(topic)")
            XCTAssertFalse(topic.text.lowercased().contains("probability"), "\(topic): confidence is not a probability")
        }
        let c = HelpTopic.modelConfidence.text
        XCTAssertTrue(c.contains("model's own estimate"))
        XCTAssertTrue(c.contains("uncalibrated"))
        XCTAssertTrue(c.contains("0.6"))
    }

    func testAccuracyTopics_nameChanceLevel() {
        for topic in [HelpTopic.heldOutAccuracy, .chanceAndBaseline, .liveRunInterval, .freeze] {
            XCTAssertTrue(topic.text.contains("chance level"), "\(topic)")
        }
        XCTAssertTrue(HelpTopic.chanceAndBaseline.text.contains("baseline"))
    }

    func testNoOverclaiming() {
        let banned = ["proves", "guarantee", "reads your mind", "brain activity is", "always accurate"]
        for topic in HelpTopic.allCases {
            for word in banned { XCTAssertFalse(topic.text.lowercased().contains(word), "\(topic): \(word)") }
        }
        XCTAssertTrue(HelpTopic.qualityChecks.text.contains("doesn't prove"))
    }

    func testQualityTopic_namesTheWorkersSixRules() {
        for rule in ["flatline", "pinned at a limit", "large deflections", "mains line", "outlier amplitude", "outlier high-frequency power"] {
            XCTAssertTrue(HelpTopic.qualityChecks.text.lowercased().contains(rule), rule)
        }
    }
}
