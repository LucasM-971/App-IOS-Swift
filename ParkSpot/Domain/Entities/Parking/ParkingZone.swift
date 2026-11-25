import Foundation

enum ParkingZone: String, Codable, CaseIterable, Sendable {
    case free        = "Gratuit"
    case paid        = "Payant"
    case resident    = "Resident"
    case underground = "Souterrain"
    case freeResident = "Gratuit+Resident"
    case freeUnderground = "Gratuit+Souterrain"
    case paidResident = "Payant+Resident"
    case paidUnderground = "Payant+Souterrain"
    case covered = "Covered"
    case freeCovered = "Gratuit+Covered"
    case paidCovered = "Payant+Covered"
    case publicParking = "public"
    case freePublicParking = "Gratuit+public"
    case paidPublicParking = "Payant+public"
    case surface = "surface"
    case freeSurface = "Gratuit+surface"
    case paidSurface = "Payant+surface"
    case other = "other"
    case freeOther = "Gratuit+other"
    case paidOther = "Payant+other"
    case unknown     = "Inconnu"

    var localizationKey: String {
        switch self {
        case .free: return "zone.free"
        case .paid: return "zone.paid"
        case .resident: return "zone.resident"
        case .underground: return "zone.underground"
        case .freeResident: return "zone.free"
        case .freeUnderground: return "zone.free"
        case .paidResident: return "zone.paid"
        case .paidUnderground: return "zone.paid"
        case .covered: return "zone.unknown"
        case .freeCovered: return "zone.free"
        case .paidCovered: return "zone.paid"
        case .publicParking: return "zone.unknown"
        case .freePublicParking: return "zone.free"
        case .paidPublicParking: return "zone.paid"
        case .surface: return "zone.unknown"
        case .freeSurface: return "zone.free"
        case .paidSurface: return "zone.paid"
        case .other: return "zone.unknown"
        case .freeOther: return "zone.free"
        case .paidOther: return "zone.paid"
        case .unknown: return "zone.unknown"
        }
    }

    var isPaidPricing: Bool {
        switch self {
        case .paid,
            .paidResident,
            .paidUnderground,
            .paidCovered,
            .paidPublicParking,
            .paidSurface,
            .paidOther:
            return true
        default:
            return false
        }
    }

    var isFreePricing: Bool {
        switch self {
        case .free,
            .resident,
            .underground,
            .freeResident,
            .freeUnderground,
            .covered,
            .freeCovered,
            .publicParking,
            .freePublicParking,
            .surface,
            .freeSurface,
            .other,
            .freeOther:
            return true
        default:
            return false
        }
    }

    var isUndergroundType: Bool {
        switch self {
        case .underground, .freeUnderground, .paidUnderground:
            return true
        default:
            return false
        }
    }

    var isResidentType: Bool {
        switch self {
        case .resident, .freeResident, .paidResident:
            return true
        default:
            return false
        }
    }

    var localizedName: String {
        switch self {
        case .free:
            return "zone.free".psLocalized
        case .paid:
            return "zone.paid".psLocalized
        case .resident:
            return "zone.resident".psLocalized
        case .underground:
            return "zone.underground".psLocalized
        case .freeResident:
            return "\("zone.free".psLocalized) + \("zone.resident".psLocalized)"
        case .freeUnderground:
            return "\("zone.free".psLocalized) + \("zone.underground".psLocalized)"
        case .paidResident:
            return "\("zone.paid".psLocalized) + \("zone.resident".psLocalized)"
        case .paidUnderground:
            return "\("zone.paid".psLocalized) + \("zone.underground".psLocalized)"
        case .covered:
            return "zone.covered".psLocalized
        case .freeCovered:
            return "\("zone.free".psLocalized) + \("zone.covered".psLocalized)"
        case .paidCovered:
            return "\("zone.paid".psLocalized) + \("zone.covered".psLocalized)"
        case .publicParking:
            return "zone.public".psLocalized
        case .freePublicParking:
            return "\("zone.free".psLocalized) + \("zone.public".psLocalized)"
        case .paidPublicParking:
            return "\("zone.paid".psLocalized) + \("zone.public".psLocalized)"
        case .surface:
            return "zone.surface".psLocalized
        case .freeSurface:
            return "\("zone.free".psLocalized) + \("zone.surface".psLocalized)"
        case .paidSurface:
            return "\("zone.paid".psLocalized) + \("zone.surface".psLocalized)"
        case .other:
            return "zone.other".psLocalized
        case .freeOther:
            return "\("zone.free".psLocalized) + \("zone.other".psLocalized)"
        case .paidOther:
            return "\("zone.paid".psLocalized) + \("zone.other".psLocalized)"
        case .unknown:
            return "zone.unknown".psLocalized
        }
    }
}
