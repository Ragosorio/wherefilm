import Foundation
import Accelerate

/// How embeddings are stored on disk.
///
/// The arithmetic that drives this choice: 27,000 videos × one representation
/// every 10 s ≈ 4.86 M vectors. At 512 dimensions that's ~10 GB in float32,
/// ~5 GB in float16 and **~2.5 GB in int8** — for an archive whose originals
/// weigh ~810 TB.
public enum VectorQuantization: String, Sendable {
    case float32
    case int8

    public var bytesPerDimension: Int {
        switch self {
        case .float32: 4
        case .int8: 1
        }
    }
}

public enum VectorCodec {
    /// L2-normalises in place. Every vector we store is unit length, which turns
    /// cosine similarity into a plain dot product.
    public static func normalized(_ vector: [Float]) -> [Float] {
        var norm: Float = 0
        vDSP_svesq(vector, 1, &norm, vDSP_Length(vector.count))
        norm = sqrt(norm)
        guard norm > 1e-12 else { return vector }
        var out = [Float](repeating: 0, count: vector.count)
        var inverse = 1 / norm
        vDSP_vsmul(vector, 1, &inverse, &out, 1, vDSP_Length(vector.count))
        return out
    }

    /// Symmetric int8 quantization. Returns the payload plus the scale needed to
    /// reconstruct it. On unit-length vectors the error is far below the noise
    /// floor of the embedding itself.
    public static func encodeInt8(_ vector: [Float]) -> (data: Data, scale: Double) {
        var maxAbs: Float = 0
        vDSP_maxmgv(vector, 1, &maxAbs, vDSP_Length(vector.count))
        let scale = maxAbs > 1e-12 ? Double(maxAbs) / 127.0 : 1.0

        var bytes = [Int8](repeating: 0, count: vector.count)
        for i in vector.indices {
            let scaled = (Double(vector[i]) / scale).rounded()
            bytes[i] = Int8(max(-127, min(127, scaled)))
        }
        return (bytes.withUnsafeBufferPointer { Data(buffer: $0) }, scale)
    }

    public static func decodeInt8(_ data: Data, scale: Double) -> [Float] {
        let floatScale = Float(scale)
        return data.withUnsafeBytes { raw -> [Float] in
            let buffer = raw.bindMemory(to: Int8.self)
            return buffer.map { Float($0) * floatScale }
        }
    }

    public static func encodeFloat32(_ vector: [Float]) -> Data {
        vector.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    public static func decodeFloat32(_ data: Data) -> [Float] {
        data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
    }

    public static func encode(_ vector: [Float], as quantization: VectorQuantization) -> (data: Data, scale: Double) {
        switch quantization {
        case .float32: (encodeFloat32(vector), 1.0)
        case .int8: encodeInt8(vector)
        }
    }

    public static func decode(_ data: Data, scale: Double, quantization: VectorQuantization) -> [Float] {
        switch quantization {
        case .float32: decodeFloat32(data)
        case .int8: decodeInt8(data, scale: scale)
        }
    }

    /// Dot product. Both sides are expected to be unit length, so this *is* the
    /// cosine similarity.
    public static func dot(_ a: [Float], _ b: [Float]) -> Float {
        precondition(a.count == b.count)
        var result: Float = 0
        vDSP_dotpr(a, 1, b, 1, &result, vDSP_Length(a.count))
        return result
    }
}
