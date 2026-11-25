import Foundation

struct APIResponse<T: Decodable>: Decodable {
    let data: T
    let message: String?
    let success: Bool
}
