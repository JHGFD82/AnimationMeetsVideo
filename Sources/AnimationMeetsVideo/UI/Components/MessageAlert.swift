import SwiftUI

extension View {
    /// An alert with only an OK button, shown while `message` has a value
    /// and clearing it when dismissed.
    func messageAlert(_ title: LocalizedStringKey, message: Binding<String?>) -> some View {
        alert(title, isPresented: message.isPresent) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(message.wrappedValue ?? "")
        }
    }
}
