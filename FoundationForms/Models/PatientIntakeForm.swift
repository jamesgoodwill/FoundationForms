import Foundation

struct PatientIntakeForm: Codable, Equatable, Sendable {
    var firstName: String?
    var lastName: String?
    var dateOfBirth: Date?
    var address: Address?
    var symptoms: String?

    struct Address: Codable, Equatable, Sendable {
        var street: String?
        var city: String?
        var state: String?
        var zip: String?
    }

    // Per-field constraints mirrored from basic_information.json. Shared so the
    // prompt generator and any UI validation reference one source of truth.
    enum MaxLength {
        static let firstName = 50
        static let lastName = 60
        static let street = 255
        static let city = 100
        static let zip = 10
        static let symptoms = 2000
    }
}
