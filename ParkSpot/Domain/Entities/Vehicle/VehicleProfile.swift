import Foundation
import CoreLocation
import Combine

struct VehicleProfile: Codable, Equatable {
    var nickname: String
    var type: VehicleType
    var averageConsumptionPer100Km: Double
    var annualDistanceKm: Double
    var energyPriceEUR: Double
    var notes: String
    var updatedAt: Date
    var brand: String?
    var model: String?
    var plateNumber: String?
    var modelYear: Int?
    var fuelKind: String?
    var tankCapacityOrBatteryKWh: Double?
    var currentMileageKm: Double?
    var lastServiceDate: Date?
    var nextServiceMileageKm: Double?
    var tirePressureBar: Double?

    var estimatedAnnualEnergyUnits: Double {
        max(0, annualDistanceKm) * max(0, averageConsumptionPer100Km) / 100.0
    }

    var estimatedMonthlyEnergyBudgetEUR: Double {
        (estimatedAnnualEnergyUnits * max(0, energyPriceEUR)) / 12.0
    }
}
