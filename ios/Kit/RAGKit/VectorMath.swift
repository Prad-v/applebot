import Foundation
#if canImport(Accelerate)
import Accelerate
#endif

public enum VectorMath {
    public static func dot(_ a: [Float], _ b: [Float]) -> Float {
        let count = min(a.count, b.count)
        guard count > 0 else { return 0 }
        #if canImport(Accelerate)
        return vDSP.dot(a.prefix(count), b.prefix(count))
        #else
        var sum: Float = 0
        for index in 0..<count { sum += a[index] * b[index] }
        return sum
        #endif
    }

    /// Dot product of `query` with the vector at `offset` in a flat row-major buffer.
    static func dot(query: [Float], flat: [Float], offset: Int) -> Float {
        let count = query.count
        #if canImport(Accelerate)
        return flat.withUnsafeBufferPointer { buffer in
            query.withUnsafeBufferPointer { q in
                var result: Float = 0
                vDSP_dotpr(q.baseAddress!, 1, buffer.baseAddress! + offset, 1, &result, vDSP_Length(count))
                return result
            }
        }
        #else
        var sum: Float = 0
        for index in 0..<count { sum += query[index] * flat[offset + index] }
        return sum
        #endif
    }

    public static func norm(_ vector: [Float]) -> Float {
        var sum: Float = 0
        for value in vector { sum += value * value }
        return sum.squareRoot()
    }

    public static func normalized(_ vector: [Float]) -> [Float] {
        let length = norm(vector)
        guard length > 1e-9 else { return vector }
        return vector.map { $0 / length }
    }

    public static func normalizedFloats(from vector: [Double]) -> [Float] {
        normalized(vector.map { Float($0) })
    }

    // MARK: Blob (de)serialisation for storage

    public static func data(from vector: [Float]) -> Data {
        vector.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    public static func vector(from data: Data) -> [Float] {
        let count = data.count / MemoryLayout<Float>.size
        var result = [Float](repeating: 0, count: count)
        _ = result.withUnsafeMutableBytes { data.copyBytes(to: $0) }
        return result
    }
}
