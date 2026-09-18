import SwiftUI

/// The runner signs in once. Only a refresh token is kept afterwards, in the
/// Keychain; the password is sent to the API and never stored.
struct SignInView: View {
    @ObservedObject var sync: CheerSync
    @Environment(\.dismiss) private var dismiss

    @State private var email = ""
    @State private var password = ""
    @State private var problem: String?
    @State private var working = false

    var body: some View {
        NavigationView {
            Form {
                Section {
                    // Username/password content types let iCloud Keychain or a
                    // password manager fill these in.
                    TextField("Email", text: $email)
                        .textContentType(.username)
                        .keyboardType(.emailAddress)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField("Password", text: $password)
                        .textContentType(.password)
                } footer: {
                    if let problem {
                        Text(problem).foregroundColor(.red)
                    }
                }

                Button {
                    Task { await submit() }
                } label: {
                    if working {
                        ProgressView()
                    } else {
                        Text("Sign in")
                    }
                }
                .disabled(email.isEmpty || password.isEmpty || working)
            }
            .navigationTitle("Sign in")
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }

    private func submit() async {
        working = true
        problem = await sync.signIn(email: email, password: password)
        working = false
        if problem == nil {
            dismiss()
        }
    }
}
