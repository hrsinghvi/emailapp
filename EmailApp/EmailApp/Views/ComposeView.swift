import SwiftUI

struct ComposeView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var to = ""
    @State private var subject = ""
    @State private var messageBody = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("New Message")
                .font(.headline)

            field("To", text: $to)
            field("Subject", text: $subject)

            TextEditor(text: $messageBody)
                .font(.body)
                .scrollContentBackground(.hidden)
                .padding(8)
                .frame(minHeight: 200)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                Button {
                    dismiss()
                } label: {
                    Text("Send")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(Capsule().fill(Color(hex: "#b58ee0").opacity(0.9)))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(20)
        .frame(width: 480, height: 420)
        .background(Color(hex: "#191919"))
    }

    private func field(_ placeholder: String, text: Binding<String>) -> some View {
        TextField(placeholder, text: text)
            .textFieldStyle(.plain)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
    }
}
