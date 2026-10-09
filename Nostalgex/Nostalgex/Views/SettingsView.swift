import SwiftUI
import Combine
import CoreImage.CIFilterBuiltins

struct SettingsView: View {
    @Environment(AppState.self) var appState
    @FocusState private var focusedControl: String?

    /// Which onboarding screen is showing while not mid-auth.
    private enum Screen { case picker, jellyfinForm, embyForm }
    @State private var screen: Screen = .picker

    // Jellyfin form inputs.
    @State private var jellyfinURL = ""
    @State private var jellyfinUser = ""
    @State private var jellyfinPass = ""
    /// True when the in-progress auth is a Quick Connect flow (drives which waiting UI shows).
    @State private var usingQuickConnect = false

    // Emby form inputs.
    @State private var embyURL = ""
    @State private var embyUser = ""
    @State private var embyPass = ""

    /// LAN discovery on the Jellyfin and Emby forms. One state for both forms; it is
    /// reset whenever the form changes so an Emby list never shows under Jellyfin.
    private enum DiscoveryState: Equatable {
        case idle
        case searching
        case found([DiscoveredServer])
        case nothingFound
    }
    @State private var discovery: DiscoveryState = .idle

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            // Mirrors ServerPickerView: branding on the left, controls on the right, so
            // connecting and choosing libraries read as one continuous flow.
            HStack(alignment: .center, spacing: 80) {

                // Left: branding
                VStack(alignment: .leading, spacing: 28) {
                    Image("NostalgexLogo")
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: 440)

                    Text("CONNECT YOUR SERVER")
                        .font(.custom("DMMono-Medium", size: 40))
                        .foregroundStyle(.white.opacity(0.9))

                    Text("Nostalgex builds a retro channel guide from your own library. Connect Plex, Jellyfin, or Emby to get started.")
                        .font(.custom("DMMono-Regular", size: 22))
                        .foregroundStyle(.white.opacity(0.45))
                        .multilineTextAlignment(.leading)
                        .lineSpacing(4)
                        // Without this the copy clips to two lines and ellipsises.
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: 560, alignment: .leading)

                    // On the very first screen, deliberately: a support report has to be able
                    // to say WHICH build is running before any sign-in exists. A stale
                    // side-install with the same display name once burned a week of
                    // credential debugging because nothing on this screen identified it.
                    Text(connectScreenVersionLabel)
                        .font(.custom("DMMono-Regular", size: 15))
                        .foregroundStyle(.white.opacity(0.25))
                    Text(InstallDiagnostics.summary())
                        .font(.custom("DMMono-Regular", size: 13))
                        .foregroundStyle(.white.opacity(0.25))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                // Right: controls
                VStack(spacing: 24) {
                    if appState.isAuthInProgress {
                        if usingQuickConnect {
                            jellyfinQuickConnectSection
                        } else if screen == .jellyfinForm || screen == .embyForm {
                            signingInSection
                        } else {
                            pinDisplaySection
                        }
                    } else {
                        switch screen {
                        case .picker: backendPickerSection
                        case .jellyfinForm: jellyfinLoginSection
                        case .embyForm: embyLoginSection
                        }
                    }
                }
                .frame(maxWidth: .infinity)
            }
            .padding(.horizontal, 100)
            .padding(.vertical, 60)
        }
        .accessibilityIdentifier("settingsScreen")
        .toolbar(.hidden, for: .navigationBar)
    }

    private var connectScreenVersionLabel: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "VERSION \(version) (\(build))"
    }

    // MARK: - Backend picker (idle state)

    private var backendPickerSection: some View {
        // Fixed column width so all three connect buttons share one edge-to-edge measure.
        VStack(spacing: 20) {
            if let error = appState.authError {
                Text(error.uppercased())
                    .font(.custom("DMMono-Medium", size: 26))
                    .foregroundStyle(Color(hex: "#FF2244"))
                    .multilineTextAlignment(.center)
            }

            // Landing here repeatedly is the symptom of a keychain that accepts a write and
            // cannot return it. Say so, rather than letting the user assume they did something
            // wrong each time they are asked to sign in again.
            if !appState.credentialsArePersistent {
                Text("THIS DEVICE ISN'T KEEPING YOUR SIGN-IN")
                    .font(.custom("DMMono-Medium", size: 22))
                    .foregroundStyle(Color(hex: "#FFB020"))
                    .multilineTextAlignment(.center)
                Text("Nostalgex saved your connection but the Apple TV did not store it, so it was lost on restart. Signing in again will work for this session. Please report this.")
                    .font(.custom("DMMono-Regular", size: 17))
                    .foregroundStyle(.white.opacity(0.45))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // A lost session names its own cause: the code is the keychain status for the
            // token read on this launch, which separates "purged item" from "not ready yet"
            // without a debugger. Absent entirely when this is a fresh install or sign-out.
            if let diagnosis = appState.signInLossDiagnostic {
                Text(diagnosis)
                    .font(.custom("DMMono-Regular", size: 17))
                    .foregroundStyle(Color(hex: "#FFB020").opacity(0.9))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // The app's own sign-outs leave a receipt too. Without this, a deliberate wipe
            // (token condemned by plex.tv) looked identical to the device losing data.
            if let notice = appState.lastSignOutNotice {
                Text(notice)
                    .font(.custom("DMMono-Regular", size: 17))
                    .foregroundStyle(Color(hex: "#FFB020").opacity(0.9))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Button {
                appState.startPINAuth()
            } label: {
                connectLabel("CONNECT TO PLEX", focused: focusedControl == "connect")
            }
            .buttonStyle(NoHaloButtonStyle())
            .focused($focusedControl, equals: "connect")
            .accessibilityIdentifier("connectToPlexButton")

            Text("OR CONNECT WITH")
                .font(.custom("DMMono-Regular", size: 20))
                .foregroundStyle(.white.opacity(0.35))
                .tracking(2)
                .padding(.top, 12)

            VStack(spacing: 16) {
                Button {
                    appState.authError = nil
                    discovery = .idle
                    screen = .jellyfinForm
                } label: {
                    secondaryConnectLabel("JELLYFIN", focused: focusedControl == "jellyfin")
                }
                .buttonStyle(NoHaloButtonStyle())
                .focused($focusedControl, equals: "jellyfin")
                .accessibilityIdentifier("connectToJellyfinButton")

                Button {
                    appState.authError = nil
                    discovery = .idle
                    screen = .embyForm
                } label: {
                    secondaryConnectLabel("EMBY", focused: focusedControl == "emby")
                }
                .buttonStyle(NoHaloButtonStyle())
                .focused($focusedControl, equals: "emby")
                .accessibilityIdentifier("connectToEmbyButton")
            }

            // Demo Mode — bundled sample channels, no account required. Primarily an
            // App Store review fallback; kept subtle so real users pick a real server.
            Button {
                appState.enterDemoMode()
            } label: {
                Text("demo mode")
                    .font(.custom("DMMono-Regular", size: 15))
                    .foregroundStyle(.white.opacity(focusedControl == "demo" ? 0.7 : 0.28))
                    .tracking(2)
            }
            .buttonStyle(NoHaloButtonStyle())
            .focused($focusedControl, equals: "demo")
            .accessibilityIdentifier("demoModeButton")
            .padding(.top, 40)
        }
        .frame(maxWidth: 560)
    }

    /// Primary cyan-bordered connect button (Plex).
    private func connectLabel(_ title: String, focused: Bool) -> some View {
        Text(title)
            .font(.custom("DMMono-Medium", size: 36))
            .foregroundStyle(Color("BrandCyan"))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 24)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color("BrandCyan").opacity(focused ? 0.16 : 0.08))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(Color("BrandCyan").opacity(focused ? 1.0 : 0.55),
                            lineWidth: focused ? 2.5 : 2)
            )
    }

    /// Smaller secondary button for Jellyfin / Emby.
    private func secondaryConnectLabel(_ title: String, focused: Bool) -> some View {
        Text(title)
            .font(.custom("DMMono-Medium", size: 28))
            .foregroundStyle(.white.opacity(focused ? 0.9 : 0.45))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 20)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.white.opacity(focused ? 0.08 : 0.04))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.white.opacity(focused ? 0.5 : 0.2),
                            lineWidth: focused ? 2 : 1.5)
            )
    }

    // MARK: - Jellyfin login form

    private var jellyfinLoginSection: some View {
        VStack(spacing: 24) {
            if let error = appState.authError {
                Text(error.uppercased())
                    .font(.custom("DMMono-Medium", size: 24))
                    .foregroundStyle(Color(hex: "#FF2244"))
                    .multilineTextAlignment(.center)
            }

            Text("CONNECT TO JELLYFIN")
                .font(.custom("DMMono-Medium", size: 30))
                .foregroundStyle(Color("BrandCyan"))

            VStack(spacing: 16) {
                jellyfinField("Server URL (e.g. http://192.168.1.10:8096)", text: $jellyfinURL, id: "jfURL", secure: false)
                discoverySection(kind: .jellyfin, idPrefix: "jf", accessibilityPrefix: "jellyfin") { address in
                    jellyfinURL = address
                    focusedControl = "jfUser"
                }
                jellyfinField("Username", text: $jellyfinUser, id: "jfUser", secure: false)
                jellyfinField("Password", text: $jellyfinPass, id: "jfPass", secure: true)
            }
            .frame(maxWidth: 760)

            HStack(spacing: 20) {
                Button {
                    usingQuickConnect = false
                    appState.authenticateJellyfin(serverURL: jellyfinURL, username: jellyfinUser, password: jellyfinPass)
                } label: {
                    actionLabel("SIGN IN", focused: focusedControl == "jfSignIn")
                }
                .buttonStyle(NoHaloButtonStyle())
                .focused($focusedControl, equals: "jfSignIn")
                .accessibilityIdentifier("jellyfinSignInButton")

                Button {
                    usingQuickConnect = true
                    appState.startJellyfinQuickConnect(serverURL: jellyfinURL)
                } label: {
                    actionLabel("USE QUICK CONNECT", focused: focusedControl == "jfQuick")
                }
                .buttonStyle(NoHaloButtonStyle())
                .focused($focusedControl, equals: "jfQuick")
                .accessibilityIdentifier("jellyfinQuickConnectButton")
            }

            Button("BACK") {
                appState.authError = nil
                discovery = .idle
                screen = .picker
            }
            .font(.custom("DMMono-Medium", size: 24))
            .foregroundStyle(.gray)
            .buttonStyle(NoHaloButtonStyle())
            .focused($focusedControl, equals: "jfBack")
            .padding(.top, 8)
        }
    }

    // MARK: - Emby login form

    private var embyLoginSection: some View {
        VStack(spacing: 24) {
            if let error = appState.authError {
                Text(error.uppercased())
                    .font(.custom("DMMono-Medium", size: 24))
                    .foregroundStyle(Color(hex: "#FF2244"))
                    .multilineTextAlignment(.center)
            }

            Text("CONNECT TO EMBY")
                .font(.custom("DMMono-Medium", size: 30))
                .foregroundStyle(Color("BrandCyan"))

            VStack(spacing: 16) {
                jellyfinField("Server URL (e.g. http://192.168.1.10:8096)", text: $embyURL, id: "emURL", secure: false)
                discoverySection(kind: .emby, idPrefix: "em", accessibilityPrefix: "emby") { address in
                    embyURL = address
                    focusedControl = "emUser"
                }
                jellyfinField("Username", text: $embyUser, id: "emUser", secure: false)
                jellyfinField("Password", text: $embyPass, id: "emPass", secure: true)
            }
            .frame(maxWidth: 760)

            Button {
                appState.authenticateEmby(serverURL: embyURL, username: embyUser, password: embyPass)
            } label: {
                actionLabel("SIGN IN", focused: focusedControl == "emSignIn")
            }
            .buttonStyle(NoHaloButtonStyle())
            .focused($focusedControl, equals: "emSignIn")
            .accessibilityIdentifier("embySignInButton")

            Button("BACK") {
                appState.authError = nil
                discovery = .idle
                screen = .picker
            }
            .font(.custom("DMMono-Medium", size: 24))
            .foregroundStyle(.gray)
            .buttonStyle(NoHaloButtonStyle())
            .focused($focusedControl, equals: "emBack")
            .padding(.top, 8)
        }
    }

    private func jellyfinField(_ placeholder: String, text: Binding<String>, id: String, secure: Bool) -> some View {
        Group {
            if secure {
                SecureField(placeholder, text: text)
            } else {
                TextField(placeholder, text: text)
            }
        }
        .textFieldStyle(.plain)
        .font(.custom("DMMono-Regular", size: 26))
        .foregroundStyle(.white)
        .padding(.horizontal, 24)
        .padding(.vertical, 18)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.06)))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color("BrandCyan").opacity(focusedControl == id ? 0.9 : 0.3),
                        lineWidth: focusedControl == id ? 2.5 : 1.5)
        )
        .focused($focusedControl, equals: id)
    }

    // MARK: - LAN discovery (Jellyfin and Emby forms)

    /// The find button, then whatever the last search produced: a list of servers to
    /// pick from, or a one-line miss. Only servers of `kind` are listed, because each
    /// kind has its own probe string and its own socket.
    @ViewBuilder
    private func discoverySection(kind: MediaBackendKind, idPrefix: String, accessibilityPrefix: String,
                                  fill: @escaping (String) -> Void) -> some View {
        let buttonID = "\(idPrefix)Find"
        let searching = discovery == .searching

        Button {
            guard !searching else { return }
            discovery = .searching
            Task {
                let servers = await LANServerDiscovery.discover(kind: kind)
                discovery = servers.isEmpty ? .nothingFound : .found(servers)
            }
        } label: {
            secondaryConnectLabel(searching ? LANServerDiscovery.Copy.searching : LANServerDiscovery.Copy.findButton,
                                  focused: focusedControl == buttonID)
        }
        .buttonStyle(NoHaloButtonStyle())
        .focused($focusedControl, equals: buttonID)
        .accessibilityIdentifier("\(accessibilityPrefix)FindServersButton")

        switch discovery {
        case .found(let servers):
            ForEach(servers) { server in
                let rowID = "\(idPrefix)Found-\(server.id)"
                Button {
                    fill(server.address)
                    discovery = .idle
                } label: {
                    discoveredServerLabel(server, focused: focusedControl == rowID)
                }
                .buttonStyle(NoHaloButtonStyle())
                .focused($focusedControl, equals: rowID)
                .accessibilityIdentifier("\(accessibilityPrefix)DiscoveredServer-\(server.id)")
            }
        case .nothingFound:
            Text(LANServerDiscovery.Copy.noneFound)
                .font(.custom("DMMono-Regular", size: 18))
                .foregroundStyle(Color(hex: "#FFB020").opacity(0.9))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("\(accessibilityPrefix)NoServersFound")
        case .idle, .searching:
            EmptyView()
        }
    }

    /// A discovered server as a focusable row: name on top, address underneath.
    private func discoveredServerLabel(_ server: DiscoveredServer, focused: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(server.name)
                .font(.custom("DMMono-Medium", size: 26))
                .foregroundStyle(.white.opacity(focused ? 0.95 : 0.7))
                .lineLimit(1)
            Text(server.address)
                .font(.custom("DMMono-Regular", size: 18))
                .foregroundStyle(Color("BrandCyan").opacity(focused ? 0.9 : 0.55))
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 24)
        .padding(.vertical, 14)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.white.opacity(focused ? 0.08 : 0.04))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color("BrandCyan").opacity(focused ? 0.9 : 0.3),
                        lineWidth: focused ? 2.5 : 1.5)
        )
    }

    private func actionLabel(_ title: String, focused: Bool) -> some View {
        Text(title)
            .font(.custom("DMMono-Medium", size: 28))
            .foregroundStyle(Color("BrandCyan"))
            .padding(.horizontal, 40)
            .padding(.vertical, 18)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color("BrandCyan").opacity(focused ? 0.16 : 0.08)))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(Color("BrandCyan").opacity(focused ? 1.0 : 0.55), lineWidth: focused ? 2.5 : 2)
            )
    }

    // MARK: - Jellyfin waiting states

    private var jellyfinQuickConnectSection: some View {
        VStack(alignment: .center, spacing: 24) {
            Text("IN JELLYFIN, OPEN QUICK CONNECT AND ENTER:")
                .font(.custom("DMMono-Medium", size: 26))
                .foregroundStyle(Color(hex: "#00C4FF"))
                .multilineTextAlignment(.center)

            Text(appState.jellyfinQuickConnectCode.isEmpty ? "------" : appState.jellyfinQuickConnectCode)
                .font(.custom("DMMono-Medium", size: 108))
                .foregroundStyle(.white)
                .kerning(16)

            WaitingIndicatorView(message: "WAITING FOR APPROVAL")

            Button("CANCEL") {
                usingQuickConnect = false
                appState.cancelPINAuth()
            }
            .font(.custom("DMMono-Medium", size: 26))
            .foregroundStyle(.gray)
        }
    }

    private var signingInSection: some View {
        VStack(spacing: 24) {
            WaitingIndicatorView(message: "SIGNING IN")
            Button("CANCEL") {
                appState.cancelPINAuth()
            }
            .font(.custom("DMMono-Medium", size: 26))
            .foregroundStyle(.gray)
        }
    }

    // MARK: - PIN display (Plex polling state)

    private var pinDisplaySection: some View {
        HStack(alignment: .center, spacing: 80) {

            // Left: instructions + PIN + status
            VStack(alignment: .leading, spacing: 24) {
                Text("GO TO plex.tv/link AND ENTER:")
                    .font(.custom("DMMono-Medium", size: 28))
                    .foregroundStyle(Color(hex: "#00C4FF"))

                Text(appState.pinCode.isEmpty ? "----" : appState.pinCode)
                    .font(.custom("DMMono-Medium", size: 108))
                    .foregroundStyle(.white)
                    .kerning(16)

                WaitingIndicatorView(message: appState.isDiscoveringServers
                    ? "FINDING YOUR SERVERS"
                    : appState.pinCode.isEmpty ? "CONNECTING TO PLEX.TV" : "WAITING FOR AUTHORIZATION")

                Button("CANCEL") {
                    appState.cancelPINAuth()
                }
                .font(.custom("DMMono-Medium", size: 26))
                .foregroundStyle(.gray)
            }

            // Right: QR code
            VStack(spacing: 12) {
                QRCodeView(url: appState.pinCode.isEmpty
                    ? "https://www.plex.tv/link/"
                    : "https://www.plex.tv/link/?pin=\(appState.pinCode)")
                    .frame(width: 200, height: 200)
                    .cornerRadius(8)

                Text("SCAN TO CONNECT")
                    .font(.custom("DMMono-Regular", size: 20))
                    .foregroundStyle(.gray.opacity(0.6))
            }
        }
    }
}

// MARK: - Button style

/// Suppresses the default tvOS white focus halo so the view can draw its own
/// cyan-bordered focus state (driven by @FocusState).
private struct NoHaloButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.98 : 1.0)
            .animation(.easeInOut(duration: 0.12), value: configuration.isPressed)
    }
}

// MARK: - QR Code

struct QRCodeView: View {
    let url: String

    var body: some View {
        if let image = generateQRCode(from: url) {
            Image(uiImage: image)
                .interpolation(.none)
                .resizable()
                .scaledToFit()
        }
    }

    private func generateQRCode(from string: String) -> UIImage? {
        let context = CIContext()
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(string.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 10, y: 10))
        guard let cgImage = context.createCGImage(scaled, from: scaled.extent) else { return nil }
        return UIImage(cgImage: cgImage)
    }
}

// MARK: - Waiting indicator

private struct WaitingIndicatorView: View {
    var message: String = "WAITING FOR AUTHORIZATION"
    @State private var dots = ""
    let timer = Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()

    var body: some View {
        Text(message + dots)
            .font(.custom("DMMono-Medium", size: 24))
            .foregroundStyle(Color(hex: "#00C4FF"))
            .onReceive(timer) { _ in
                dots = dots.count >= 3 ? "" : dots + "."
            }
    }
}
