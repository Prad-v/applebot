import SwiftUI
import AVFoundation
import UIKit
import CoreVideo

/// Live camera preview with still capture and optional continuous frames for Live mode.
struct SurroundingsCameraPreview: UIViewRepresentable {
    var onCapture: (UIImage) -> Void
    var onLiveFrame: ((UIImage) -> Void)?
    var liveFramesEnabled: Bool
    @Binding var captureTrigger: Int
    @Binding var sessionRunning: Bool
    @Binding var cameraError: String?

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        context.coordinator.attach(to: view, onCapture: onCapture, onLiveFrame: onLiveFrame)
        context.coordinator.setLiveFramesEnabled(liveFramesEnabled)
        context.coordinator.start()
        return view
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {
        context.coordinator.onCapture = onCapture
        context.coordinator.onLiveFrame = onLiveFrame
        context.coordinator.setLiveFramesEnabled(liveFramesEnabled)
        if context.coordinator.lastTrigger != captureTrigger {
            context.coordinator.lastTrigger = captureTrigger
            context.coordinator.capturePhoto()
        }
        DispatchQueue.main.async {
            sessionRunning = context.coordinator.isRunning
            cameraError = context.coordinator.errorMessage
        }
    }

    static func dismantleUIView(_ uiView: PreviewView, coordinator: Coordinator) {
        coordinator.stop()
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    }

    /// Capture delegates hop across queues; guarded with `lock` for live-frame state.
    final class Coordinator: NSObject, AVCapturePhotoCaptureDelegate, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
        var onCapture: ((UIImage) -> Void)?
        var onLiveFrame: ((UIImage) -> Void)?
        var lastTrigger = 0
        private(set) var isRunning = false
        private(set) var errorMessage: String?

        private let session = AVCaptureSession()
        private let photoOutput = AVCapturePhotoOutput()
        private let videoOutput = AVCaptureVideoDataOutput()
        private let sessionQueue = DispatchQueue(label: "dev.kekaflow.applebot.surroundings.camera")
        private let frameQueue = DispatchQueue(label: "dev.kekaflow.applebot.surroundings.frames")
        private weak var preview: PreviewView?
        private let lock = NSLock()
        private var liveFramesEnabled = false
        private var lastLiveEmit: CFTimeInterval = 0
        /// Minimum gap between live frame callbacks (~2s).
        private let liveMinInterval: CFTimeInterval = 2.0

        func attach(
            to view: PreviewView,
            onCapture: @escaping (UIImage) -> Void,
            onLiveFrame: ((UIImage) -> Void)?
        ) {
            self.preview = view
            self.onCapture = onCapture
            self.onLiveFrame = onLiveFrame
            view.previewLayer.session = session
            view.previewLayer.videoGravity = .resizeAspectFill
        }

        func setLiveFramesEnabled(_ enabled: Bool) {
            lock.lock()
            liveFramesEnabled = enabled
            if !enabled { lastLiveEmit = 0 }
            lock.unlock()
        }

        func start() {
            sessionQueue.async { [weak self] in
                self?.configureAndStart()
            }
        }

        func stop() {
            sessionQueue.async { [weak self] in
                guard let self else { return }
                if self.session.isRunning {
                    self.session.stopRunning()
                }
                DispatchQueue.main.async {
                    self.isRunning = false
                }
            }
        }

        func capturePhoto() {
            sessionQueue.async { [weak self] in
                guard let self else { return }
                guard self.session.isRunning else {
                    DispatchQueue.main.async {
                        self.errorMessage = SurroundingsError.cameraUnavailable.localizedDescription
                    }
                    return
                }
                let settings = AVCapturePhotoSettings()
                self.photoOutput.capturePhoto(with: settings, delegate: self)
            }
        }

        private func configureAndStart() {
            session.beginConfiguration()
            session.sessionPreset = .high

            for input in session.inputs {
                session.removeInput(input)
            }
            for output in session.outputs {
                session.removeOutput(output)
            }

            guard
                let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
                let input = try? AVCaptureDeviceInput(device: device),
                session.canAddInput(input),
                session.canAddOutput(photoOutput),
                session.canAddOutput(videoOutput)
            else {
                session.commitConfiguration()
                DispatchQueue.main.async {
                    self.errorMessage = SurroundingsError.cameraUnavailable.localizedDescription
                    self.isRunning = false
                }
                return
            }

            session.addInput(input)
            session.addOutput(photoOutput)

            videoOutput.alwaysDiscardsLateVideoFrames = true
            videoOutput.videoSettings = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
            ]
            videoOutput.setSampleBufferDelegate(self, queue: frameQueue)
            session.addOutput(videoOutput)

            session.commitConfiguration()
            session.startRunning()
            DispatchQueue.main.async {
                self.errorMessage = nil
                self.isRunning = self.session.isRunning
            }
        }

        func photoOutput(
            _ output: AVCapturePhotoOutput,
            didFinishProcessingPhoto photo: AVCapturePhoto,
            error: Error?
        ) {
            if let error {
                DispatchQueue.main.async {
                    self.errorMessage = error.localizedDescription
                }
                return
            }
            guard let data = photo.fileDataRepresentation(), let image = UIImage(data: data) else {
                DispatchQueue.main.async {
                    self.errorMessage = SurroundingsError.captureFailed.localizedDescription
                }
                return
            }
            DispatchQueue.main.async {
                self.onCapture?(image)
            }
        }

        func captureOutput(
            _ output: AVCaptureOutput,
            didOutput sampleBuffer: CMSampleBuffer,
            from connection: AVCaptureConnection
        ) {
            lock.lock()
            let enabled = liveFramesEnabled
            let last = lastLiveEmit
            lock.unlock()
            guard enabled else { return }

            let now = CACurrentMediaTime()
            guard now - last >= liveMinInterval else { return }

            lock.lock()
            lastLiveEmit = now
            lock.unlock()

            guard let image = Self.image(from: sampleBuffer) else { return }
            // Downscale for Vision cost.
            let scaled = Self.scaled(image, maxDimension: 960)
            DispatchQueue.main.async {
                self.onLiveFrame?(scaled)
            }
        }

        private static func image(from sampleBuffer: CMSampleBuffer) -> UIImage? {
            guard let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return nil }
            let ciImage = CIImage(cvPixelBuffer: buffer)
            let context = CIContext(options: nil)
            guard let cgImage = context.createCGImage(ciImage, from: ciImage.extent) else { return nil }
            return UIImage(cgImage: cgImage, scale: 1, orientation: .right)
        }

        private static func scaled(_ image: UIImage, maxDimension: CGFloat) -> UIImage {
            let size = image.size
            let longest = max(size.width, size.height)
            guard longest > maxDimension, longest > 0 else { return image }
            let scale = maxDimension / longest
            let newSize = CGSize(width: size.width * scale, height: size.height * scale)
            let renderer = UIGraphicsImageRenderer(size: newSize)
            return renderer.image { _ in
                image.draw(in: CGRect(origin: .zero, size: newSize))
            }
        }
    }
}
