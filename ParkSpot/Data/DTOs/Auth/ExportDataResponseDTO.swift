import Foundation

struct ExportDataResponseDTO: Decodable {
    let fileName: String
    let contentType: String
    let content: String
    let generatedAt: Date
}
