import Foundation

extension PatientIntakeForm {
    /// System-instructions string for a Foundation Models extraction session.
    ///
    /// `self` is the current state of the form — already-captured fields are listed
    /// so the model preserves them across turns instead of re-extracting from scratch.
    func extractionInstructions() -> String {
        var lines: [String] = []
        lines.append("You extract structured patient-intake data from the user's conversational message.")
        lines.append("Return a PatientIntakeFormExtraction with the following fields:")
        lines.append("")
        lines.append("- firstName (string, required, max \(MaxLength.firstName) chars) — patient's legal first name.")
        lines.append("- lastName (string, required, max \(MaxLength.lastName) chars) — patient's legal last name.")
        lines.append("- dateOfBirth (string, required) — date of birth in ISO 8601 YYYY-MM-DD format.")
        lines.append("- address.street (string, required, max \(MaxLength.street) chars).")
        lines.append("- address.city (string, required, max \(MaxLength.city) chars).")
        lines.append("- address.state (string, required) — two-letter US postal code in uppercase, e.g. \"CA\".")
        lines.append("- address.zip (string, required, max \(MaxLength.zip) chars) — US ZIP code.")
        lines.append("- symptoms (string, required, max \(MaxLength.symptoms) chars) — patient's reported symptoms in their own words.")
        lines.append("")

        let known = knownFieldLines()
        if !known.isEmpty {
            lines.append("Already captured from prior turns. Preserve these exactly unless the user explicitly corrects them:")
            for line in known { lines.append("- \(line)") }
            lines.append("")
        }

        lines.append("RULES:")
        lines.append("- Only extract information explicitly stated by the user. Do not infer or add data.")
        lines.append("- If a field is not mentioned, leave it null.")
        lines.append("- Do not invent or guess names, dates, addresses, ZIP codes, or symptoms.")
        lines.append("- Preserve the user's own wording for free-text fields like symptoms.")
        lines.append("- Return only structured field values — no prose, no commentary.")
        return lines.joined(separator: "\n")
    }

    private func knownFieldLines() -> [String] {
        var out: [String] = []
        if let v = firstName, !v.isEmpty { out.append("firstName: \(v)") }
        if let v = lastName, !v.isEmpty { out.append("lastName: \(v)") }
        if let d = dateOfBirth { out.append("dateOfBirth: \(Self.isoString(from: d))") }
        if let a = address {
            if let v = a.street, !v.isEmpty { out.append("address.street: \(v)") }
            if let v = a.city, !v.isEmpty { out.append("address.city: \(v)") }
            if let v = a.state, !v.isEmpty { out.append("address.state: \(v)") }
            if let v = a.zip, !v.isEmpty { out.append("address.zip: \(v)") }
        }
        if let v = symptoms, !v.isEmpty { out.append("symptoms: \(v)") }
        return out
    }
}
