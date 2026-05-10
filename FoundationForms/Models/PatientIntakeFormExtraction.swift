import Foundation
import FoundationModels

// LLM-facing mirror of `PatientIntakeForm`. `Date` and other rich types aren't
// supported by `@Generable` directly, so dates round-trip through ISO 8601 strings
// and we fold the result back into the domain model via `init(merging:into:)`.
@Generable
struct PatientIntakeFormExtraction: Sendable {

    @Guide(description: "Patient's legal first name. Maximum 50 characters.")
    var firstName: String?

    @Guide(description: "Patient's legal last name. Maximum 60 characters.")
    var lastName: String?

    @Guide(description: "Patient's date of birth as an ISO 8601 calendar date in YYYY-MM-DD format, e.g. \"1985-04-23\".")
    var dateOfBirth: String?

    @Guide(description: "Patient's mailing address. Omit any sub-field the user did not state.")
    var address: AddressExtraction?

    @Guide(description: "Patient's reported symptoms in their own words. Maximum 2000 characters.")
    var symptoms: String?

    @Generable
    struct AddressExtraction: Sendable {
        @Guide(description: "Street address including number, name, and unit if any. Maximum 255 characters.")
        var street: String?

        @Guide(description: "City name. Maximum 100 characters.")
        var city: String?

        @Guide(description: "Two-letter US state postal code in uppercase, e.g. \"CA\" or \"NY\".")
        var state: String?

        @Guide(description: "5- or 9-digit US ZIP code, e.g. \"94103\" or \"94103-1234\". Maximum 10 characters.")
        var zip: String?
    }
}

extension PatientIntakeForm {
    /// Overlays an LLM extraction onto an existing form. Empty/nil extracted values
    /// are ignored so confirmed fields from prior turns survive.
    init(merging extraction: PatientIntakeFormExtraction, into base: PatientIntakeForm = .init()) {
        self = base
        if let v = extraction.firstName?.nonEmpty { firstName = v }
        if let v = extraction.lastName?.nonEmpty { lastName = v }
        if let v = extraction.dateOfBirth?.nonEmpty, let date = Self.parseISODate(v) {
            dateOfBirth = date
        }
        if let v = extraction.symptoms?.nonEmpty { symptoms = v }

        if let ea = extraction.address {
            var a = base.address ?? Address()
            if let v = ea.street?.nonEmpty { a.street = v }
            if let v = ea.city?.nonEmpty { a.city = v }
            if let v = ea.state?.nonEmpty { a.state = v.uppercased() }
            if let v = ea.zip?.nonEmpty { a.zip = v }
            address = a
        }
    }

    nonisolated static func parseISODate(_ s: String) -> Date? {
        try? Date(s.trimmingCharacters(in: .whitespaces),
                  strategy: Date.ISO8601FormatStyle().year().month().day())
    }

    nonisolated static func isoString(from date: Date) -> String {
        date.formatted(Date.ISO8601FormatStyle().year().month().day())
    }
}

private extension String {
    var nonEmpty: String? {
        let t = trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }
}
