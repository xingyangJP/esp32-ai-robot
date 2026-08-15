import Foundation
import Security
import CryptoKit
import AuthenticationServices
import FirebaseAuth

/// Owns the app's Firebase identity. REMOTE mode pairs the phone and the home
/// bridge by the SAME Firebase uid (the relay derives room = verified uid), so the
/// phone signs in with Apple → Firebase, and the bridge mints a custom token for
/// this same uid (see host_brain/firebase_auth.py). LAN mode never needs this.
@MainActor
final class AuthStore: ObservableObject {
    @Published var uid: String?
    @Published var email: String?
    @Published var errorMessage: String?

    /// Nonce for the in-flight Sign in with Apple request (replay protection).
    private var currentNonce: String?

    var isSignedIn: Bool { uid != nil }

    init() {
        uid = Auth.auth().currentUser?.uid
        email = Auth.auth().currentUser?.email
        // Keep uid in sync if the session is restored/refreshed/revoked.
        _ = Auth.auth().addStateDidChangeListener { [weak self] _, user in
            Task { @MainActor in self?.uid = user?.uid; self?.email = user?.email }
        }
    }

    /// A fresh (auto-refreshed) Firebase ID token for the relay hello, or "" if
    /// signed out. The relay verifies it and uses its uid as the room.
    func idToken() async -> String {
        guard let user = Auth.auth().currentUser else { return "" }
        return (try? await user.getIDToken()) ?? ""
    }

    func signOut() {
        try? Auth.auth().signOut()
        uid = nil; email = nil
    }

    // MARK: Sign in with Apple (wired to SwiftUI's SignInWithAppleButton)
    func configureRequest(_ req: ASAuthorizationAppleIDRequest) {
        errorMessage = nil
        let nonce = Self.randomNonce()
        currentNonce = nonce
        req.requestedScopes = [.fullName, .email]
        req.nonce = Self.sha256(nonce)
    }

    func handleCompletion(_ result: Result<ASAuthorization, Error>) {
        switch result {
        case .failure(let e):
            // User-cancelled is not an error worth surfacing.
            if (e as? ASAuthorizationError)?.code == .canceled { return }
            errorMessage = e.localizedDescription
        case .success(let authorization):
            guard let cred = authorization.credential as? ASAuthorizationAppleIDCredential,
                  let nonce = currentNonce,
                  let tokenData = cred.identityToken,
                  let idToken = String(data: tokenData, encoding: .utf8) else {
                errorMessage = "Apple sign-in returned a malformed credential."
                return
            }
            let firebaseCred = OAuthProvider.appleCredential(withIDToken: idToken,
                                                             rawNonce: nonce,
                                                             fullName: cred.fullName)
            Task {
                do {
                    let r = try await Auth.auth().signIn(with: firebaseCred)
                    self.uid = r.user.uid
                    self.email = r.user.email
                } catch {
                    self.errorMessage = error.localizedDescription
                }
            }
        }
    }

    // MARK: nonce helpers
    private static func randomNonce(_ length: Int = 32) -> String {
        let charset = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz-._")
        var result = ""
        var remaining = length
        while remaining > 0 {
            var randoms = [UInt8](repeating: 0, count: 16)
            guard SecRandomCopyBytes(kSecRandomDefault, randoms.count, &randoms) == errSecSuccess else {
                continue
            }
            for r in randoms where remaining > 0 {
                if Int(r) < charset.count { result.append(charset[Int(r)]); remaining -= 1 }
            }
        }
        return result
    }

    private static func sha256(_ input: String) -> String {
        SHA256.hash(data: Data(input.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
