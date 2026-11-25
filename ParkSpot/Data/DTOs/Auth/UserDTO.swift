import Foundation

struct UserDTO: Decodable {
    let id: String
    let email: String
    let displayName: String
    let isPremium: Bool?
    let status: String?
    let statusId: Int?
    let createdAt: Date

    private enum CodingKeys: String, CodingKey {
        case id
        case email
        case displayName
        case isPremium
        case status
        case statusId
        case roleId
        case statusRoleId
        case subscriptionStatus
        case createdAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        id = (try? container.decode(String.self, forKey: .id)) ?? ""
        email = (try? container.decode(String.self, forKey: .email)) ?? ""
        displayName = (try? container.decode(String.self, forKey: .displayName)) ?? "Utilisateur"
        isPremium = Self.decodeLossyBool(container, keys: [.isPremium])
        status = Self.decodeLossyString(container, keys: [.status, .subscriptionStatus])
        statusId = Self.decodeLossyInt(container, keys: [.statusId, .roleId, .statusRoleId])
        createdAt = (try? container.decode(Date.self, forKey: .createdAt)) ?? .now
    }

    func toDomain() -> User {
        User(
            id: UUID(uuidString: id) ?? UUID(),
            email: email,
            displayName: displayName,
            isPremium: resolvedPremiumFlag,
            status: status,
            statusId: statusId,
            createdAt: createdAt
        )
    }

    private var resolvedPremiumFlag: Bool {
        if statusId == 1 { return false }
        if normalizedStatus(status) == "free" { return false }

        if statusId == 2 || statusId == 3 { return true }
        if let normalized = normalizedStatus(status),
           normalized == "paid"
            || normalized == "premium"
            || normalized == "paid_monthly"
            || normalized == "paid_lifetime" {
            return true
        }

        return isPremium ?? false
    }

    private func normalizedStatus(_ value: String?) -> String? {
        guard let value else { return nil }
        return value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "-", with: "_")
            .replacingOccurrences(of: " ", with: "_")
    }

    private static func decodeLossyBool(
        _ container: KeyedDecodingContainer<CodingKeys>,
        keys: [CodingKeys]
    ) -> Bool? {
        for key in keys {
            if let value = try? container.decode(Bool.self, forKey: key) {
                return value
            }
            if let number = try? container.decode(Int.self, forKey: key) {
                if number == 1 { return true }
                if number == 0 { return false }
            }
            if let text = try? container.decode(String.self, forKey: key) {
                let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                if ["true", "1", "yes", "y", "on", "paid", "premium", "paid_monthly", "paid_lifetime"].contains(normalized) {
                    return true
                }
                if ["false", "0", "no", "n", "off", "free"].contains(normalized) {
                    return false
                }
            }
        }
        return nil
    }

    private static func decodeLossyInt(
        _ container: KeyedDecodingContainer<CodingKeys>,
        keys: [CodingKeys]
    ) -> Int? {
        for key in keys {
            if let value = try? container.decode(Int.self, forKey: key) {
                return value
            }
            if let text = try? container.decode(String.self, forKey: key) {
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if let value = Int(trimmed) {
                    return value
                }
            }
        }
        return nil
    }

    private static func decodeLossyString(
        _ container: KeyedDecodingContainer<CodingKeys>,
        keys: [CodingKeys]
    ) -> String? {
        for key in keys {
            if let value = try? container.decode(String.self, forKey: key),
               !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return value
            }
        }
        return nil
    }
}
