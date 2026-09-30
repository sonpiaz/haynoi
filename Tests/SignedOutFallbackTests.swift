import XCTest
@testable import Haynoi

/// 30/09, 0.3.12: "tốc độ ra cực kỳ nhanh nhưng … sai chính tả sai chữ sai phát âm".
/// Fast and wrong on English terms is the offline recognizer's signature; signed
/// out, it is what gets pasted, and nothing told the user.
final class SignedOutFallbackTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_000_000)

    func testWarnsWhenSignedOutTextCameFromOffline() {
        XCTAssertTrue(PipelineController.shouldWarnSignedOut(source: .onDevice, error: STTError.notSignedIn,
                                                             lastWarned: nil, now: now))
    }

    func testAtMostOnceEveryTenMinutes() {
        XCTAssertFalse(PipelineController.shouldWarnSignedOut(source: .onDevice, error: STTError.notSignedIn,
                                                              lastWarned: now.addingTimeInterval(-599), now: now))
        XCTAssertTrue(PipelineController.shouldWarnSignedOut(source: .onDevice, error: STTError.notSignedIn,
                                                             lastWarned: now.addingTimeInterval(-600), now: now))
    }

    func testNoWarningForOtherFailuresOrCloudText() {
        XCTAssertFalse(PipelineController.shouldWarnSignedOut(source: .cloud, error: STTError.notSignedIn,
                                                              lastWarned: nil, now: now))
        XCTAssertFalse(PipelineController.shouldWarnSignedOut(source: .onDevice, error: STTError.sessionExpired,
                                                              lastWarned: nil, now: now), "has its own notice")
        XCTAssertFalse(PipelineController.shouldWarnSignedOut(source: .onDevice, error: URLError(.notConnectedToInternet),
                                                              lastWarned: nil, now: now))
    }
}

/// The seven words 0.3.12 got wrong on 30/09, as the pronunciation hint sees them.
/// Measured: none of them was blocked by 8c64eb2's diacritic rule — two are not
/// sound-alikes of their term at all, five have no term in the dictionary.
final class MisheardPairsTests: XCTestCase {

    func testPairsTheHintCanReachOnceTheTermIsInTheDictionary() {
        for (heard, term) in [("em đi", "MD"), ("ATM mail", "HTML"), ("Mak mini", "Mac mini"), ("iPod", "Pidot")] {
            XCTAssertTrue(Phonetics.close(heard, term), "\(heard) → \(term)")
        }
    }

    func testPairsThatAreNotSoundAlikes() {
        // Vietnamese final "ch" keys as "c", English "ck" as "k"; "agent" keeps its j.
        for (heard, term) in [("đếch", "deck"), ("Asian", "agent"), ("bút", "output")] {
            XCTAssertFalse(Phonetics.close(heard, term), "\(heard) → \(term)")
        }
    }
}
