import AuthenticationServices
import UIKit
import ConnectorKit

/// Shows the provider's sign-in page in the system's secure browser sheet (`ASWebAuthenticationSession`).
///
/// The app never sees the user's password, and the sheet shares Safari's session, so users who are
/// already signed in to Google only have to confirm.
@MainActor
final class WebAuthSession: NSObject, WebAuthenticator, ASWebAuthenticationPresentationContextProviding {
    private var session: ASWebAuthenticationSession?

    func authenticate(url: URL, callbackScheme: String) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(url: url, callbackURLScheme: callbackScheme) { callback, error in
                if let callback {
                    continuation.resume(returning: callback)
                } else if let error = error as? ASWebAuthenticationSessionError, error.code == .canceledLogin {
                    continuation.resume(throwing: ConnectorError.cancelled)
                } else {
                    continuation.resume(throwing: ConnectorError.authenticationFailed(
                        error?.localizedDescription ?? "Sign-in did not complete."
                    ))
                }
            }
            session.presentationContextProvider = self
            // Share Safari cookies so an existing Google session is reused.
            session.prefersEphemeralWebBrowserSession = false
            self.session = session
            if !session.start() {
                continuation.resume(throwing: ConnectorError.authenticationFailed("Could not open the sign-in page."))
            }
        }
    }

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let windows = scenes.flatMap(\.windows)
        if let window = windows.first(where: \.isKeyWindow) ?? windows.first { return window }
        // Sign-in starts from a button on screen, so a scene always exists here.
        guard let scene = scenes.first else { preconditionFailure("No window scene to present sign-in from") }
        return UIWindow(windowScene: scene)
    }
}
