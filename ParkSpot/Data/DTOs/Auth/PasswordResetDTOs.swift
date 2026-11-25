import Foundation

struct PasswordResetRequestResponseDTO: Decodable {
    let requiresEmailConfirmation: Bool?
}

struct EmailCodeVerificationForPasswordResetResponseDTO: Decodable {
    let ok: Bool?
}
