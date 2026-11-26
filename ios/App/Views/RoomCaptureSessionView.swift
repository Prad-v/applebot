import SwiftUI

#if canImport(RoomPlan)
import RoomPlan
import UIKit

/// Presents Apple’s RoomPlan capture UI; returns a processed `CapturedRoom` or cancel.
struct RoomCaptureSessionView: UIViewControllerRepresentable {
    var onComplete: (CapturedRoom) -> Void
    var onCancel: () -> Void

    func makeUIViewController(context: Context) -> RoomCaptureHostController {
        let host = RoomCaptureHostController()
        host.onComplete = onComplete
        host.onCancel = onCancel
        return host
    }

    func updateUIViewController(_ uiViewController: RoomCaptureHostController, context: Context) {
        uiViewController.onComplete = onComplete
        uiViewController.onCancel = onCancel
    }
}

final class RoomCaptureHostController: UIViewController, RoomCaptureViewDelegate {
    var onComplete: ((CapturedRoom) -> Void)?
    var onCancel: (() -> Void)?

    private var roomCaptureView: RoomCaptureView!
    private var isScanning = false
    private var finalResults: CapturedRoom?
    private let activity = UIActivityIndicatorView(style: .large)
    private let instruction = UILabel()

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black

        roomCaptureView = RoomCaptureView(frame: view.bounds)
        roomCaptureView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        roomCaptureView.delegate = self
        view.addSubview(roomCaptureView)

        instruction.text = "Move slowly around the room. Tap Done when finished."
        instruction.textColor = .white
        instruction.font = .preferredFont(forTextStyle: .footnote)
        instruction.numberOfLines = 0
        instruction.textAlignment = .center
        instruction.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(instruction)

        activity.hidesWhenStopped = true
        activity.color = .white
        activity.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(activity)

        let cancel = UIBarButtonItem(barButtonSystemItem: .cancel, target: self, action: #selector(cancelTapped))
        let done = UIBarButtonItem(barButtonSystemItem: .done, target: self, action: #selector(doneTapped))
        navigationItem.leftBarButtonItem = cancel
        navigationItem.rightBarButtonItem = done
        navigationItem.title = "Scan room"

        NSLayoutConstraint.activate([
            instruction.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 16),
            instruction.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -16),
            instruction.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -16),
            activity.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            activity.centerYAnchor.constraint(equalTo: view.centerYAnchor),
        ])
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        startSession()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        if isScanning {
            roomCaptureView?.captureSession.stop(pauseARSession: true)
            isScanning = false
        }
    }

    private func startSession() {
        isScanning = true
        finalResults = nil
        let config = RoomCaptureSession.Configuration()
        roomCaptureView.captureSession.run(configuration: config)
        instruction.text = "Move slowly around the room. Tap Done when finished."
        activity.stopAnimating()
    }

    @objc private func cancelTapped() {
        if isScanning {
            roomCaptureView.captureSession.stop(pauseARSession: true)
            isScanning = false
        }
        onCancel?()
    }

    @objc private func doneTapped() {
        if isScanning {
            isScanning = false
            roomCaptureView.captureSession.stop(pauseARSession: false)
            instruction.text = "Processing scan…"
            activity.startAnimating()
            navigationItem.rightBarButtonItem?.isEnabled = false
        } else if let finalResults {
            onComplete?(finalResults)
        }
    }

    nonisolated func captureView(shouldPresent roomDataForProcessing: CapturedRoomData, error: Error?) -> Bool {
        true
    }

    nonisolated func captureView(didPresent processedResult: CapturedRoom, error: Error?) {
        Task { @MainActor in
            self.activity.stopAnimating()
            self.navigationItem.rightBarButtonItem?.isEnabled = true
            if let error {
                self.instruction.text = error.localizedDescription
                return
            }
            self.finalResults = processedResult
            self.instruction.text = "Scan ready."
            // Auto-complete so the user doesn’t need a second Done tap after processing.
            self.onComplete?(processedResult)
        }
    }
}
#endif
