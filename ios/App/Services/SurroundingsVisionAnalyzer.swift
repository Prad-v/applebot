import Foundation
import UIKit
import ConnectorKit
import LLMKit

#if canImport(Vision)
import Vision
#endif

#if canImport(ARKit)
import ARKit
#endif

/// Runs on-device Vision (and optional LiDAR capability notes) on a captured frame.
enum SurroundingsVisionAnalyzer {
    static func capabilities() -> SurroundingsCapabilities {
        #if canImport(ARKit)
        let lidar = ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh)
            || ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth)
        #else
        let lidar = false
        #endif
        #if canImport(Vision)
        let vision = true
        #else
        let vision = false
        #endif
        return SurroundingsCapabilities(
            camera: true,
            onDeviceVision: vision,
            lidarDepthAssist: lidar
        )
    }

    static func analyze(image: UIImage) async throws -> SurroundingsFacts {
        let caps = capabilities()
        var notes = caps.warnings.filter { $0.contains("LiDAR") }

        #if canImport(Vision)
        guard let cgImage = image.cgImage else {
            throw SurroundingsError.invalidImage
        }

        let orientation = CGImagePropertyOrientation(image.imageOrientation)
        async let labels = classify(cgImage: cgImage, orientation: orientation)
        async let texts = recognizeText(cgImage: cgImage, orientation: orientation)
        async let humans = countHumans(cgImage: cgImage, orientation: orientation)

        let classifications = try await labels
        let recognized = try await texts
        let humanCount = try await humans

        let depthHint: String? = caps.lidarDepthAssist
            ? "LiDAR depth assist is available on this iPhone; use distances as approximate only."
            : nil

        return SurroundingsFacts(
            classifications: classifications,
            recognizedText: recognized,
            humanCount: humanCount,
            depthHint: depthHint,
            sensorNotes: notes,
            capturedAt: Date()
        )
        #else
        notes.append("On-device Vision is unavailable on this build.")
        return SurroundingsFacts(sensorNotes: notes)
        #endif
    }

    #if canImport(Vision)
    private static func classify(
        cgImage: CGImage,
        orientation: CGImagePropertyOrientation
    ) async throws -> [String] {
        try await withCheckedThrowingContinuation { continuation in
            let request = VNClassifyImageRequest { request, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                let results = (request.results as? [VNClassificationObservation]) ?? []
                let labels = results
                    .filter { $0.confidence >= 0.15 }
                    .prefix(8)
                    .map { "\($0.identifier) (\(Int(($0.confidence * 100).rounded()))%)" }
                continuation.resume(returning: Array(labels))
            }
            let handler = VNImageRequestHandler(cgImage: cgImage, orientation: orientation, options: [:])
            do {
                try handler.perform([request])
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    private static func recognizeText(
        cgImage: CGImage,
        orientation: CGImagePropertyOrientation
    ) async throws -> [String] {
        try await withCheckedThrowingContinuation { continuation in
            let request = VNRecognizeTextRequest { request, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                let observations = (request.results as? [VNRecognizedTextObservation]) ?? []
                let lines = observations.compactMap { $0.topCandidates(1).first?.string }
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
                continuation.resume(returning: Array(lines.prefix(16)))
            }
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            let handler = VNImageRequestHandler(cgImage: cgImage, orientation: orientation, options: [:])
            do {
                try handler.perform([request])
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    private static func countHumans(
        cgImage: CGImage,
        orientation: CGImagePropertyOrientation
    ) async throws -> Int {
        try await withCheckedThrowingContinuation { continuation in
            let request = VNDetectHumanRectanglesRequest { request, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                let count = (request.results as? [VNHumanObservation])?.count ?? 0
                continuation.resume(returning: count)
            }
            let handler = VNImageRequestHandler(cgImage: cgImage, orientation: orientation, options: [:])
            do {
                try handler.perform([request])
            } catch {
                // Older devices / simulators may not support human rectangles — treat as zero.
                continuation.resume(returning: 0)
            }
        }
    }
    #endif
}

enum SurroundingsError: LocalizedError {
    case invalidImage
    case cameraUnavailable
    case permissionDenied
    case captureFailed

    var errorDescription: String? {
        switch self {
        case .invalidImage: return "Could not read that camera frame."
        case .cameraUnavailable: return "Camera is not available on this device."
        case .permissionDenied: return "Camera access was denied. Allow Camera for Applebot in Settings."
        case .captureFailed: return "Could not capture a photo. Try again."
        }
    }
}

#if canImport(Vision)
private extension CGImagePropertyOrientation {
    init(_ orientation: UIImage.Orientation) {
        switch orientation {
        case .up: self = .up
        case .down: self = .down
        case .left: self = .left
        case .right: self = .right
        case .upMirrored: self = .upMirrored
        case .downMirrored: self = .downMirrored
        case .leftMirrored: self = .leftMirrored
        case .rightMirrored: self = .rightMirrored
        @unknown default: self = .up
        }
    }
}
#endif
