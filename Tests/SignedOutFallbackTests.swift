import XCTest
@testable import Haynoi

/// 30/09, 0.3.12: "tốc độ ra cực kỳ nhanh nhưng … sai chính tả sai chữ sai phát âm".
/// Fast and wrong on English terms is the offline recognizer's signature; signed
/// out, it is what gets pasted, and nothing told the user.
final class SignedOutFallbackTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_000_000)
    private func notice(_ source: PipelineController.Source, _ error: Error, _ last: Date? = nil) -> PipelineController.OfflineNotice? {
        PipelineController.offlineNotice(source: source, error: error, lastWarned: last, now: now)
    }

    func testSignedOutSaysSignedOut() {
        XCTAssertEqual(notice(.onDevice, STTError.notSignedIn), .signedOut)
    }

    /// W37-1574: any cloud failure that ends in offline text is said, not only sign-out.
    func testEveryOtherCloudFailureSaysOffline() {
        for error: Error in [STTError.serverError("x"), STTError.rateLimited, STTError.noConnection,
                             STTError.outOfCredits, URLError(.timedOut)] {
            XCTAssertEqual(notice(.onDevice, error), .cloudFailed, "\(error)")
        }
    }

    func testAtMostOnceEveryTenMinutes() {
        XCTAssertNil(notice(.onDevice, STTError.noConnection, now.addingTimeInterval(-599)))
        XCTAssertEqual(notice(.onDevice, STTError.noConnection, now.addingTimeInterval(-600)), .cloudFailed)
    }

    func testNoNoticeForCloudTextOrExpiredSession() {
        XCTAssertNil(notice(.cloud, STTError.notSignedIn))
        XCTAssertNil(notice(.onDevice, STTError.sessionExpired), "has its own notice")
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
