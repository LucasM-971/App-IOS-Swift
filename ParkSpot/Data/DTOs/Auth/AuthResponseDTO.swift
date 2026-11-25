import Foundation

struct AuthResponseDTO: Decodable {
    let accessToken: String
    let refreshToken: String
    let user: UserDTO
}
