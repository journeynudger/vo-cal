import AuthenticationServices
import CryptoKit
import Foundation
import UIKit

/// Runs the native Sign in with Apple sheet and returns the identity token + the raw nonce
/// that Supabase needs for `signInWithIdToken`. The nonce is the standard replay defense:
/// we send Apple the SHA-256 of a random nonce and hand Supabase the raw value, so the token
/// it verifies is bound to this request.
///
/// A continuation bridges ASAuthorizationController's delegate callbacks into async/await.
@MainActor
final class AppleSignIn: NSObject {
    struct Credential {
        let idToken: String
        let rawNonce: String
    }

    enum SignInError: LocalizedError {
        case cancelled
        case missingIdentityToken
        case failed(String)

        var errorDescription: String? {
            switch self {
            case .cancelled: return "apple_sign_in_cancelled"
            case .missingIdentityToken: return "apple_sign_in_no_identity_token"
            case let .failed(reason): return "apple_sign_in_failed:\(reason)"
            }
        }
    }

    private var continuation: CheckedContinuation<Credential, Error>?
    private var rawNonce = ""

    func signIn() async throws -> Credential {
        let nonce = Self.randomNonce()
        rawNonce = nonce
        let request = ASAuthorizationAppleIDProvider().createRequest()
        // Email only — we don't read or store the name, so don't ask the consent sheet for it.
        request.requestedScopes = [.email]
        request.nonce = Self.sha256(nonce)

        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            let controller = ASAuthorizationController(authorizationRequests: [request])
            controller.delegate = self
            controller.presentationContextProvider = self
            controller.performRequests()
        }
    }

    private static func randomNonce(length: Int = 32) -> String {
        let charset: [Character] = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz-._")
        var result = ""
        var remaining = length
        while remaining > 0 {
            var random: UInt8 = 0
            _ = SecRandomCopyBytes(kSecRandomDefault, 1, &random)
            if random < charset.count {
                result.append(charset[Int(random)])
                remaining -= 1
            }
        }
        return result
    }

    private static func sha256(_ input: String) -> String {
        SHA256.hash(data: Data(input.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

extension AppleSignIn: ASAuthorizationControllerDelegate {
    func authorizationController(
        controller: ASAuthorizationController,
        didCompleteWithAuthorization authorization: ASAuthorization
    ) {
        guard
            let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
            let tokenData = credential.identityToken,
            let idToken = String(data: tokenData, encoding: .utf8)
        else {
            continuation?.resume(throwing: SignInError.missingIdentityToken)
            continuation = nil
            return
        }
        continuation?.resume(returning: Credential(idToken: idToken, rawNonce: rawNonce))
        continuation = nil
    }

    func authorizationController(
        controller: ASAuthorizationController,
        didCompleteWithError error: Error
    ) {
        let authError = error as? ASAuthorizationError
        let mapped: SignInError =
            authError?.code == .canceled ? .cancelled : .failed(error.localizedDescription)
        continuation?.resume(throwing: mapped)
        continuation = nil
    }
}

extension AppleSignIn: ASAuthorizationControllerPresentationContextProviding {
    func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let windows = scenes.flatMap(\.windows)
        if let window = windows.first(where: \.isKeyWindow) ?? windows.first {
            return window
        }
        // No window exists anywhere — impossible while the auth sheet is being presented (the
        // app is foreground with a key window). Bind a new window to the foreground scene;
        // `init(windowScene:)` is the only non-deprecated UIWindow initializer on iOS 26.
        let scene = scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
        return UIWindow(windowScene: scene!)
    }
}
