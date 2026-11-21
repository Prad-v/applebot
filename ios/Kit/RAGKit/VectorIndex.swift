import Foundation

/// Brute-force cosine index over unit-length vectors, stored contiguously for speed.
struct VectorIndex {
    struct Result: Equatable {
        var id: UUID
        var cosine: Float
    }

    private(set) var dimension: Int
    private var ids: [UUID] = []
    private var owners: [UUID] = []
    private var flat: [Float] = []

    init(dimension: Int) {
        self.dimension = dimension
    }

    var count: Int { ids.count }

    mutating func add(id: UUID, documentID: UUID, vector: [Float]) {
        guard vector.count == dimension else { return }
        ids.append(id)
        owners.append(documentID)
        flat.append(contentsOf: vector)
    }

    mutating func remove(documentID: UUID) {
        var newIDs: [UUID] = [], newOwners: [UUID] = [], newFlat: [Float] = []
        newFlat.reserveCapacity(flat.count)
        for index in ids.indices where owners[index] != documentID {
            newIDs.append(ids[index])
            newOwners.append(owners[index])
            newFlat.append(contentsOf: flat[(index * dimension)..<((index + 1) * dimension)])
        }
        ids = newIDs; owners = newOwners; flat = newFlat
    }

    mutating func removeAll() {
        ids = []; owners = []; flat = []
    }

    func vector(for id: UUID) -> [Float]? {
        guard let index = ids.firstIndex(of: id) else { return nil }
        return Array(flat[(index * dimension)..<((index + 1) * dimension)])
    }

    func search(query: [Float], limit: Int, allowedDocuments: Set<UUID>? = nil) -> [Result] {
        guard query.count == dimension, !ids.isEmpty else { return [] }
        var results: [Result] = []
        results.reserveCapacity(ids.count)
        for index in ids.indices {
            if let allowedDocuments, !allowedDocuments.contains(owners[index]) { continue }
            let cosine = VectorMath.dot(query: query, flat: flat, offset: index * dimension)
            results.append(Result(id: ids[index], cosine: cosine))
        }
        return results
            .sorted { $0.cosine != $1.cosine ? $0.cosine > $1.cosine : $0.id.uuidString < $1.id.uuidString }
            .prefix(limit)
            .map { $0 }
    }
}
