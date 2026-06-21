import XCTest
@testable import VotelliText

final class TextProcessingTests: XCTestCase {
    func testTrimsWhitespace() {
        XCTAssertEqual(TextProcessing.clean("  hello world  "), "hello world")
    }

    func testRemovesBlankAudioAnnotation() {
        XCTAssertEqual(TextProcessing.clean("[BLANK_AUDIO]"), "")
        XCTAssertEqual(TextProcessing.clean(" [ Music ] hello"), "hello")
    }

    func testRemovesNonSpeechParentheticals() {
        XCTAssertEqual(TextProcessing.clean("(wind blowing) testing"), "testing")
        XCTAssertEqual(TextProcessing.clean("(silence)"), "")
    }

    func testKeepsOrdinaryParentheticals() {
        XCTAssertEqual(TextProcessing.clean("call me (please) today"), "call me (please) today")
    }

    func testCollapsesInternalWhitespace() {
        XCTAssertEqual(TextProcessing.clean("hello    there\nfriend"), "hello there friend")
    }

    func testKeepsNormalSentence() {
        XCTAssertEqual(TextProcessing.clean(" The quick brown fox."), "The quick brown fox.")
    }
}
