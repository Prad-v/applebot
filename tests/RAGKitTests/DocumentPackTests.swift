import XCTest
@testable import RAGKit
@testable import LLMKit

final class DocumentPackTests: XCTestCase {
    func testComposeAndParse() {
        let title = DocumentPack.compose(pack: "Voice notes", title: "Design sync")
        XCTAssertEqual(title, "Voice notes / Design sync")
        let parsed = DocumentPack.parse(title)
        XCTAssertEqual(parsed.pack, "Voice notes")
        XCTAssertEqual(parsed.title, "Design sync")
    }

    func testFilterAndListPacks() {
        let records = [
            DocumentRecord(title: "Voice notes / A", sourceName: "a", contentHash: "1", chunkCount: 1),
            DocumentRecord(title: "Work / Spec", sourceName: "b", contentHash: "2", chunkCount: 1),
            DocumentRecord(title: "Plain", sourceName: "c", contentHash: "3", chunkCount: 1),
        ]
        XCTAssertEqual(DocumentPack.filter(records, pack: "Voice notes").count, 1)
        XCTAssertEqual(DocumentPack.packs(in: records), ["Voice notes", "Work"])
        XCTAssertNil(DocumentPack.pack(of: records[2]))
    }
}
