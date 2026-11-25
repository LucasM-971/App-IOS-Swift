import Foundation

struct LoginRequestDTO: Encodable {
    let email: String
    let password: String
}

struct RegisterRequestDTO: Encodable {
    let email: String
    let password: String
    let displayName: String
    let gdprConsent: Bool      // RGPD – explicit consent required
    let consentDate: Date
}

struct RegisterResponseDTO: Decodable {
    let accessToken: String?
    let refreshToken: String?
    let user: UserDTO?
    let requiresEmailConfirmation: Bool?
    let confirmationEmail: String?
}
