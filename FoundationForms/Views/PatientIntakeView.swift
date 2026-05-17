import SwiftUI

struct PatientIntakeView: View {
    @State private var viewModel: PatientIntakeViewModel
    @Environment(\.horizontalSizeClass) private var hSizeClass

    init(viewModel: PatientIntakeViewModel = PatientIntakeViewModel()) {
        _viewModel = State(initialValue: viewModel)
    }

    var body: some View {
        Group {
            if hSizeClass == .regular {
                HStack(spacing: 0) {
                    conversation
                        .frame(maxWidth: .infinity)
                    Divider()
                    formSidebar
                        .frame(width: 340)
                }
            } else {
                VStack(spacing: 0) {
                    conversation
                    Divider()
                    formSidebar
                        .frame(maxHeight: 280)
                }
            }
        }
        .navigationTitle("Patient Intake")
        .navigationBarTitleDisplayMode(.inline)
        .task { viewModel.prewarm() }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    viewModel.reset()
                } label: {
                    Label("New Patient", systemImage: "person.badge.plus")
                }
            }
        }
    }

    private var conversation: some View {
        ConversationView(
            messages: viewModel.messages,
            draft: $viewModel.draft,
            isWorking: viewModel.isWorking,
            availability: viewModel.availability,
            inputPlaceholder: "Tell me about the patient…",
            unavailableTitle: "Intake is unavailable",
            onSend: { Task { await viewModel.send() } }
        )
        .id(viewModel.resetCount)
    }

    private var formSidebar: some View {
        Form {
            Section("Patient") {
                FieldRow(label: "First name", value: viewModel.form.firstName)
                FieldRow(label: "Last name", value: viewModel.form.lastName)
                FieldRow(
                    label: "Date of birth",
                    value: viewModel.form.dateOfBirth?.formatted(date: .abbreviated, time: .omitted)
                )
            }
            Section("Address") {
                FieldRow(label: "Street", value: viewModel.form.address?.street)
                FieldRow(label: "City", value: viewModel.form.address?.city)
                FieldRow(label: "State", value: viewModel.form.address?.state)
                FieldRow(label: "ZIP", value: viewModel.form.address?.zip)
            }
            Section("Symptoms") {
                FieldRow(label: "Symptoms", value: viewModel.form.symptoms, multiline: true)
            }
        }
        .formStyle(.grouped)
    }
}

private struct FieldRow: View {
    let label: String
    let value: String?
    var multiline: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(displayValue)
                .font(.body)
                .foregroundStyle(hasValue ? .primary : .secondary)
                .lineLimit(multiline ? nil : 1)
        }
        .padding(.vertical, 2)
    }

    private var hasValue: Bool {
        guard let value else { return false }
        return !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var displayValue: String {
        hasValue ? value! : "—"
    }
}

#Preview {
    NavigationStack {
        PatientIntakeView()
    }
}
