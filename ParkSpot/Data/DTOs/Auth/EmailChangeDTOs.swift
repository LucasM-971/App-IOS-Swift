import Foundation

struct EmailChangeRequestResponseDTO: Decodable {
    let pendingEmail: String?
    let requiresEmailConfirmation: Bool?
}

struct EmailChangeConfirmationResponseDTO: Decodable {
    let ok: Bool?
    let requiresCurrentEmailConfirmation: Bool?
    let user: UserDTO?
}
