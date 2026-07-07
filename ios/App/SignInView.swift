import CairnsKit
import SwiftUI
import UIKit

/// GitHub device flow: request a code, show it large with a copy button and a
/// link to github.com, then poll for authorization in the background.
struct SignInView: View {
    let model: AppModel
    @State private var deviceCode: DeviceCode?
    @State private var error: String?
    @State private var busy = false

    var body: some View {
        VStack(spacing: 28) {
            if let deviceCode {
                codeView(deviceCode)
            } else {
                startView
            }
            if let error {
                Text(error).font(.footnote).foregroundStyle(.red)
            }
        }
        .padding()
    }

    private var startView: some View {
        VStack(spacing: 16) {
            Image(systemName: "mountain.2.fill")
                .font(.system(size: 48)).foregroundStyle(.secondary)
            Text("Cairns").font(.title.bold())
            Text("Capture notes straight to your GitHub repo.")
                .foregroundStyle(.secondary).multilineTextAlignment(.center)
            Button("Sign in with GitHub", action: start)
                .buttonStyle(.borderedProminent)
                // Prominent buttons default to a white label, which fails
                // contrast on the pale dark-mode accent; OnAccent adapts.
                .foregroundStyle(Color("OnAccent"))
                .disabled(busy)
        }
    }

    private func codeView(_ code: DeviceCode) -> some View {
        VStack(spacing: 16) {
            Text("Enter this code on GitHub").foregroundStyle(.secondary)
            Text(code.userCode)
                .font(.system(size: 44, weight: .bold, design: .monospaced))
                .textSelection(.enabled)
            Button {
                UIPasteboard.general.string = code.userCode
            } label: {
                Label("Copy code", systemImage: "doc.on.doc")
            }
            Link(destination: code.verificationURI) {
                Label("Open github.com", systemImage: "arrow.up.right.square")
            }
            .buttonStyle(.borderedProminent)
            .foregroundStyle(Color("OnAccent"))
            ProgressView("Waiting for authorization…").padding(.top)
        }
    }

    private func start() {
        busy = true
        error = nil
        Task {
            do {
                let auth = GitHubAuth()
                let code = try await auth.requestDeviceCode()
                deviceCode = code
                let token = try await auth.waitForAuthorization(code)
                let user = try await GitHubAPI(token: token).user()
                await model.completeSignIn(token: token, login: user.login)
            } catch {
                self.error = "Sign-in failed. Please try again."
                deviceCode = nil
            }
            busy = false
        }
    }
}
