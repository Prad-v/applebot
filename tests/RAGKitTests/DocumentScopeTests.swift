import XCTest
@testable import RAGKit

final class DocumentScopeTests: XCTestCase {
    private let a = UUID(), b = UUID(), c = UUID()

    func testAttachingToAllDocumentsNarrowsToTheNewOnes() {
        XCTAssertEqual(DocumentScope.attaching([a], to: []), [a])
        XCTAssertEqual(DocumentScope.attaching([a, b], to: []), [a, b])
    }

    func testAttachingAddsToExistingScopeWithoutDuplicates() {
        XCTAssertEqual(DocumentScope.attaching([b, a], to: [a]), [a, b])
        XCTAssertEqual(DocumentScope.attaching([a], to: [a]), [a])
    }

    func testAttachingNothingKeepsScope() {
        XCTAssertEqual(DocumentScope.attaching([], to: [a, b]), [a, b])
        XCTAssertEqual(DocumentScope.attaching([], to: []), [])
    }

    func testRemovingLastDocumentFallsBackToAll() {
        XCTAssertEqual(DocumentScope.removing(a, from: [a, b]), [b])
        XCTAssertEqual(DocumentScope.removing(b, from: [b]), [])
        XCTAssertEqual(DocumentScope.removing(c, from: [a]), [a])
    }

    func testPrunedDropsDeletedDocuments() {
        XCTAssertEqual(DocumentScope.pruned([a, b, c], existing: [a, c]), [a, c])
        XCTAssertEqual(DocumentScope.pruned([a], existing: []), [])
    }

    func testSearchScopeIsNilForAllAndSetOtherwise() {
        XCTAssertNil(DocumentScope.searchScope([], existing: [a, b]))
        XCTAssertEqual(DocumentScope.searchScope([a, b], existing: [a, b, c]), [a, b])
        // A scope whose documents were all deleted widens to "all" rather than returning nothing.
        XCTAssertNil(DocumentScope.searchScope([a], existing: [b, c]))
    }

    func testScopedSearchOnlyReturnsAttachedDocuments() async throws {
        let kb = KnowledgeBase(store: InMemoryChunkStore(), embedder: HashingEmbedder())
        guard case .added(let first) = try await kb.ingest(title: "Attached", text: "battery charging guide for the camera"),
              case .added(let second) = try await kb.ingest(title: "Library", text: "battery recycling rules in the city")
        else { return XCTFail("not added") }

        let existing: Set<UUID> = [first.id, second.id]
        let attached = DocumentScope.attaching([first.id], to: [])
        let hits = try await kb.search(
            query: "battery", limit: 5, scope: DocumentScope.searchScope(attached, existing: existing)
        )
        XCTAssertEqual(Set(hits.map(\.documentTitle)), ["Attached"])
    }
}
