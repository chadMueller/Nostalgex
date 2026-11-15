import SwiftUI
import Combine
import os
import CoreImage.CIFilterBuiltins

/// The connect screens: pick a backend, then Plex's code, or for Jellyfin and Emby find
/// the server, check it, and sign in the shortest way it allows.
///
/// Jellyfin and Emby, as few presses as the server allows:
/// - The search starts as the screen opens; FIND MY SERVER is first and focused as the
///   retry. One server answering goes straight to it. Nothing answering (or the Local
///   Network prompt declined) leaves focus on TYPE AN ADDRESS.
/// - The address is checked before anyone types, so a Jellyfin server with Quick Connect
///   on opens straight on the code (nothing typed), and a server that lists its users
///   (Emby does by default) shows them as tiles, so the name is a press, not typing.
/// - Closing the keyboard moves on: address to the check, username to password,
///   password to SIGN IN (or straight to sign-in with Done).
/// The decisions live in `SignInFlow`; sign-in itself is still AppState's.
struct SettingsView: View {
    @Environment(AppState.self) var appState
    @FocusState private var focusedControl: String?

    private enum Screen: Equatable {
        case picker
        case find(MediaBackendKind)
        case typeAddress(MediaBackendKind)
        case signIn(SignInFlow.CheckedServer)
    }
    @State private var screen: Screen = .picker

    private enum Discovery: Equatable {
        case idle
        case searching
        case several([DiscoveredServer])
        case nothingFound
        /// Nothing of the kind searched for, but a server of the other kind answered (Jellyfin and Emby).
        case otherKind(MediaBackendKind, [DiscoveredServer])
    }
    @State private var discovery: Discovery = .idle

    /// "CONNECTING TO ..." while an address is being checked; nil otherwise.
    @State private var checkingLabel: String?
    @State private var checkTask: Task<Void, Never>?
    /// Bumped on every screen change so a late discovery or check result is dropped.
    @State private var flowToken = 0
    /// A line about the flow itself (address check failed, kind switched).
    @State private var flowMessage: String?

    @State private var address = ""
    @State private var username = ""
    @State private var password = ""
    /// Set when a user tile is picked; nil while typing a name.
    @State private var pickedUser: SignInFlow.PublicUser?
    /// True after SOMEONE ELSE: show the username field even though tiles exist.
    @State private var typingName = false
    /// True while the in-progress auth is Quick Connect (drives which waiting UI shows).
    @State private var usingQuickConnect = false
    /// Set by the search that starts when a Jellyfin or Emby screen opens. That first
    /// search is what brings up tvOS's Local Network prompt, and while the prompt is up
    /// nothing can answer, so when the app comes back from the prompt it searches once more.
    /// Where focus goes once the keyboard closes. tvOS hands focus back to the field the
    /// keyboard came from a moment after it closes, so the move waits for that hand-back
    /// (see the focusedControl onChange) rather than racing it with a timer.
    @State private var focusAfterKeyboard: (from: String, to: String)?
    /// The text field the keyboard was last opened from. While the keyboard is up, focus
    /// belongs to the keyboard, so this is how its closing knows which field it was.
    @State private var lastField: String?
    @State private var retryAfterPrompt = false
    @State private var retryWhenSearchEnds = false
    @Environment(\.scenePhase) private var scenePhase

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
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                // Right: controls
                VStack(spacing: 24) {
                    if appState.isAuthInProgress {
                        if usingQuickConnect {
                            quickConnectSection
                        } else if case .signIn = screen {
                            signingInSection
                        } else {
                            pinDisplaySection
                        }
                    } else if let checkingLabel {
                        checkingSection(checkingLabel)
                    } else {
                        switch screen {
                        case .picker: backendPickerSection
                        case .find(let kind): findSection(kind)
                        case .typeAddress(let kind): typeAddressSection(kind)
                        case .signIn(let server): signInSection(server)
                        }
                    }
                }
                .frame(maxWidth: .infinity)
            }
            .padding(.horizontal, 100)
            .padding(.vertical, 60)
        }
        // .contain keeps each control's own identifier; without it the screen's identifier
        // replaced every child's, so no button on this screen could be found by id.
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("settingsScreen")
        // The keychain and storage diagnostics used to sit under VERSION on this screen.
        // They go to the log now (subsystem com.muellhaus.nostalgex, category auth), where
        // a sign-in that didn't survive a restart can still be read off a device.
        .onAppear {
            InstallDiagnostics.log.notice("connect screen: \(InstallDiagnostics.summary(), privacy: .public)")
        }
        .toolbar(.hidden, for: .navigationBar)
        .defaultFocus($focusedControl, defaultFocusID)
        .onChange(of: focusKey, initial: true) { _, _ in focusSoon(defaultFocusID) }
        .onChange(of: focusedControl) { _, now in
            if let now, ["address", "username", "password"].contains(now) { lastField = now }
            guard let pending = focusAfterKeyboard else { return }
            if now == pending.from {
                focusAfterKeyboard = nil
                focusedControl = pending.to
            } else if now == pending.to {
                focusAfterKeyboard = nil
            }
        }
        // The keyboard closing, by Done or by Back, is the viewer saying "that's it": the
        // address gets checked, and the name and password move on to the next control, so
        // no DOWN-then-SELECT is needed after typing.
        .onReceive(NotificationCenter.default.publisher(for: UITextField.textDidEndEditingNotification)) { _ in
            keyboardClosed()
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active, retryAfterPrompt, case .find(let kind) = screen else { return }
            switch discovery {
            case .searching:
                retryWhenSearchEnds = true
            case .nothingFound, .otherKind:
                retryAfterPrompt = false
                findServers(kind)
            case .idle, .several:
                break
            }
        }
    }

    private func keyboardClosed() {
        guard !appState.isAuthInProgress, checkingLabel == nil else { return }
        switch (lastField, screen) {
        case ("address", .typeAddress(let kind)):
            submitAddress(kind)
        case ("username", .signIn):
            focusSoon("password", leaving: "username")
        case ("password", .signIn):
            focusSoon("signin", leaving: "password")
        default:
            break
        }
    }

    private func submitAddress(_ kind: MediaBackendKind) {
        let typed = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !typed.isEmpty else { return }
        checkServer(kind, address: typed, label: typed)
    }

    private var connectScreenVersionLabel: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "VERSION \(version) (\(build))"
    }

    // MARK: - Focus

    /// Which section is up. A change moves focus to that section's first choice, so the
    /// remote always starts somewhere visible (a fresh launch used to start with nothing
    /// focused, and the first press only found the screen).
    private var focusKey: String {
        if appState.isAuthInProgress { return usingQuickConnect ? "qc" : "auth" }
        if checkingLabel != nil { return "checking" }
        switch screen {
        case .picker: return "picker"
        case .find(let kind):
            switch discovery {
            case .several(let list): return "find-\(kind.rawValue)-several-\(list.count)"
            case .nothingFound: return "find-\(kind.rawValue)-none"
            case .otherKind(let other, let list): return "find-\(kind.rawValue)-other-\(other.rawValue)-\(list.count)"
            case .idle, .searching: return "find-\(kind.rawValue)"
            }
        case .typeAddress(let kind): return "type-\(kind.rawValue)"
        case .signIn(let server): return "signin-\(server.url)"
        }
    }

    private var defaultFocusID: String {
        if appState.isAuthInProgress { return usingQuickConnect ? "usePassword" : "cancel" }
        if checkingLabel != nil { return "cancel" }
        switch screen {
        case .picker: return "plex"
        case .find:
            switch discovery {
            case .several(let list): return list.first.map { "found-\($0.id)" } ?? "find"
            case .nothingFound: return "type"
            case .otherKind(_, let list): return list.first.map { "switch-\($0.id)" } ?? "type"
            case .idle, .searching: return "find"
            }
        case .typeAddress: return "address"
        case .signIn(let server):
            if pickedUser != nil { return "password" }
            if let first = server.users.first, !typingName { return "user-\(first.id)" }
            return "username"
        }
    }

    /// Focus set in the same pass as the view appears is dropped on tvOS; a beat later sticks.
    /// After the keyboard closes, tvOS hands focus back to the field it was opened from,
    /// so a move away from that field (`leaving`) has to wait for that first.
    private func focusSoon(_ id: String, leaving field: String? = nil) {
        guard let field else {
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(120))
                focusedControl = id
            }
            return
        }
        // Moves the moment tvOS hands focus back to `field`; the timer is only a fallback
        // for a hand-back that never comes.
        focusAfterKeyboard = (field, id)
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(900))
            guard let pending = focusAfterKeyboard, pending.to == id else { return }
            focusAfterKeyboard = nil
            if focusedControl == nil || focusedControl == field { focusedControl = id }
        }
    }

    // MARK: - Navigation

    /// `search` starts discovery as the screen opens. Only the picker asks for it: coming
    /// BACK to the find screen must not search again, or one server answering would bounce
    /// the viewer straight back to the screen they just left.
    private func go(to next: Screen, search: Bool = false) {
        flowToken += 1
        retryAfterPrompt = false
        retryWhenSearchEnds = false
        focusAfterKeyboard = nil
        checkTask?.cancel()
        checkTask = nil
        checkingLabel = nil
        discovery = .idle
        flowMessage = nil
        appState.authError = nil
        usingQuickConnect = false
        username = ""
        password = ""
        pickedUser = nil
        typingName = false
        screen = next
        if search, case .find(let kind) = next {
            retryAfterPrompt = true
            findServers(kind)
        }
    }

    private func findServers(_ kind: MediaBackendKind) {
        guard discovery != .searching else { return }
        flowMessage = nil
        appState.authError = nil
        discovery = .searching
        let token = flowToken
        Task { @MainActor in
            let servers = await SignInFlow.discover(kind: kind)
            guard token == flowToken, screen == .find(kind) else { return }
            switch SignInFlow.outcome(of: servers) {
            case .none where retryWhenSearchEnds:
                // The Local Network prompt was answered while this search ran: ask again.
                retryWhenSearchEnds = false
                retryAfterPrompt = false
                discovery = .idle
                findServers(kind)
            case .none:
                // Nothing of this kind: look for the other one before saying nothing answered.
                if let other = SignInFlow.otherKind(of: kind) {
                    let others = await SignInFlow.discover(kind: other)
                    guard token == flowToken, screen == .find(kind) else { return }
                    if let found = SignInFlow.otherKindFound(searched: kind, other: others) {
                        discovery = .otherKind(other, found)
                        return
                    }
                }
                discovery = .nothingFound
            case .single(let server):
                // One answer: no pick, straight to it.
                retryAfterPrompt = false
                discovery = .idle
                checkServer(kind, address: server.address, label: server.name)
            case .several(let list):
                retryAfterPrompt = false
                discovery = .several(list)
            }
        }
    }

    /// Asks the address who it is, then opens the right way in. On failure the viewer
    /// stays on the screen they came from, with the reason.
    private func checkServer(_ kind: MediaBackendKind, address: String, label: String) {
        checkTask?.cancel()
        flowMessage = nil
        appState.authError = nil
        checkingLabel = label
        let token = flowToken
        checkTask = Task { @MainActor in
            do {
                let server = try await SignInFlow.check(address: address)
                guard !Task.isCancelled, token == flowToken else { return }
                checkingLabel = nil
                open(server, asked: kind)
            } catch {
                guard !Task.isCancelled, token == flowToken else { return }
                checkingLabel = nil
                flowMessage = (error as? SignInFlow.CheckError) == .notAServer
                    ? SignInFlow.Copy.notAServer
                    : AppState.serverUnreachableMessage(error, backend: kind.displayName)
            }
        }
    }

    private func open(_ server: SignInFlow.CheckedServer, asked kind: MediaBackendKind) {
        go(to: .signIn(server))
        if server.kind != kind { flowMessage = SignInFlow.Copy.switchedKind(server.kind) }
        if server.preferredMethod == .quickConnect {
            startQuickConnect(server)
        }
    }

    private func startQuickConnect(_ server: SignInFlow.CheckedServer) {
        appState.authError = nil
        usingQuickConnect = true
        appState.startJellyfinQuickConnect(serverURL: server.url)
    }

    private func signIn(_ server: SignInFlow.CheckedServer) {
        usingQuickConnect = false
        let name = pickedUser?.name ?? username
        switch server.kind {
        case .jellyfin: appState.authenticateJellyfin(serverURL: server.url, username: name, password: password)
        case .emby: appState.authenticateEmby(serverURL: server.url, username: name, password: password)
        case .plex: break
        }
    }

    private var currentKind: MediaBackendKind {
        switch screen {
        case .picker: return .plex
        case .find(let kind), .typeAddress(let kind): return kind
        case .signIn(let server): return server.kind
        }
    }

    // MARK: - Backend picker (idle state)

    private var backendPickerSection: some View {
        // Fixed column width so all three connect buttons share one edge-to-edge measure.
        VStack(spacing: 22) {
            if let error = appState.authError {
                Text(error.uppercased())
                    .font(.custom("DMMono-Medium", size: 26))
                    .foregroundStyle(OnboardingPalette.error)
                    .multilineTextAlignment(.center)
            }

            // Landing here repeatedly is the symptom of a keychain that accepts a write and
            // cannot return it. Say so, rather than letting the user assume they did something
            // wrong each time they are asked to sign in again.
            if !appState.credentialsArePersistent {
                Text("THIS DEVICE ISN'T KEEPING YOUR SIGN-IN")
                    .font(.custom("DMMono-Medium", size: 22))
                    .foregroundStyle(OnboardingPalette.warning)
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
                    .foregroundStyle(OnboardingPalette.warning.opacity(0.9))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // The app's own sign-outs leave a receipt too. Without this, a deliberate wipe
            // (token condemned by plex.tv) looked identical to the device losing data.
            if let notice = appState.lastSignOutNotice {
                Text(notice)
                    .font(.custom("DMMono-Regular", size: 17))
                    .foregroundStyle(OnboardingPalette.warning.opacity(0.9))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Button("CONNECT TO PLEX") {
                appState.startPINAuth()
            }
            .buttonStyle(OnboardingButtonStyle(role: .primary))
            .focused($focusedControl, equals: "plex")
            .accessibilityIdentifier("connectToPlexButton")

            Text("OR CONNECT WITH")
                .font(.custom("DMMono-Regular", size: 20))
                .foregroundStyle(.white.opacity(0.35))
                .tracking(2)
                .padding(.top, 10)

            Button("JELLYFIN") { go(to: .find(.jellyfin), search: true) }
                .buttonStyle(OnboardingButtonStyle(role: .secondary))
                .focused($focusedControl, equals: "jellyfin")
                .accessibilityIdentifier("connectToJellyfinButton")

            Button("EMBY") { go(to: .find(.emby), search: true) }
                .buttonStyle(OnboardingButtonStyle(role: .secondary))
                .focused($focusedControl, equals: "emby")
                .accessibilityIdentifier("connectToEmbyButton")

            // Demo Mode: bundled sample channels, no account required. Primarily an
            // App Store review fallback; small so real users pick a real server, but
            // it lights up like everything else when the remote lands on it.
            Button("demo mode") { appState.enterDemoMode() }
                .buttonStyle(OnboardingButtonStyle(role: .quiet, fullWidth: false, fontSize: 18))
                .focused($focusedControl, equals: "demo")
                .accessibilityIdentifier("demoModeButton")
                .padding(.top, 30)
        }
        .frame(maxWidth: 600)
    }

    // MARK: - Jellyfin / Emby: find the server

    private func findSection(_ kind: MediaBackendKind) -> some View {
        let searching = discovery == .searching
        let findLabel: String
        switch discovery {
        case .searching: findLabel = LANServerDiscovery.Copy.searching
        case .nothingFound, .several, .otherKind: findLabel = SignInFlow.Copy.searchAgain
        case .idle: findLabel = LANServerDiscovery.Copy.findButton
        }
        let prefix = kind == .jellyfin ? "jellyfin" : "emby"

        return VStack(spacing: 22) {
            stepTitle(SignInFlow.Copy.connectTitle(kind))
            Text(SignInFlow.Copy.findIntro(kind))
                .font(.custom("DMMono-Regular", size: 22))
                .foregroundStyle(.white.opacity(0.5))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            flowMessageView

            if case .several(let servers) = discovery {
                caption(SignInFlow.Copy.pickServer)
                ForEach(servers) { server in
                    Button {
                        checkServer(kind, address: server.address, label: server.name)
                    } label: {
                        VStack(spacing: 6) {
                            Text(server.name)
                            Text(server.address)
                                .font(.custom("DMMono-Regular", size: 20))
                                .opacity(0.75)
                        }
                    }
                    .buttonStyle(OnboardingButtonStyle(role: .secondary))
                    .focused($focusedControl, equals: "found-\(server.id)")
                    .accessibilityIdentifier("\(prefix)DiscoveredServer-\(server.id)")
                }
            }

            if case .otherKind(let other, let servers) = discovery {
                Text(SignInFlow.Copy.foundOtherKind(searched: kind, found: other, names: servers.map(\.name)))
                    .font(.custom("DMMono-Regular", size: 20))
                    .foregroundStyle(OnboardingPalette.warning.opacity(0.95))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("\(prefix)OtherKindFound")
                ForEach(servers) { server in
                    // Straight to that server's sign-in, its address filled in, as if it had been found there.
                    Button(SignInFlow.Copy.switchTo(other, name: server.name)) {
                        go(to: .find(other))
                        checkServer(other, address: server.address, label: server.name)
                    }
                    .buttonStyle(OnboardingButtonStyle(role: .primary))
                    .focused($focusedControl, equals: "switch-\(server.id)")
                    .accessibilityIdentifier("\(prefix)SwitchTo-\(server.id)")
                }
            }

            if discovery == .nothingFound {
                Text(LANServerDiscovery.Copy.noneFound)
                    .font(.custom("DMMono-Regular", size: 20))
                    .foregroundStyle(OnboardingPalette.warning.opacity(0.95))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("\(prefix)NoServersFound")
            }

            Button(findLabel) {
                guard !searching else { return }
                findServers(kind)
            }
            .buttonStyle(OnboardingButtonStyle(role: discovery == .idle || searching ? .primary : .secondary))
            .focused($focusedControl, equals: "find")
            .accessibilityIdentifier("\(prefix)FindServersButton")

            Button(SignInFlow.Copy.typeAddress) { go(to: .typeAddress(kind)) }
                .buttonStyle(OnboardingButtonStyle(role: .secondary))
                .focused($focusedControl, equals: "type")
                .accessibilityIdentifier("\(prefix)TypeAddressButton")

            backButton { go(to: .picker) }
        }
        .frame(maxWidth: 720)
    }

    // MARK: - Jellyfin / Emby: typed address

    private func typeAddressSection(_ kind: MediaBackendKind) -> some View {
        VStack(spacing: 24) {
            stepTitle(SignInFlow.Copy.connectTitle(kind))
            flowMessageView
            // Closing the keyboard, by Done or Back, checks the address; CONNECT is there
            // for anyone who comes back to the field without retyping.
            OnboardingField(caption: SignInFlow.Copy.addressTitle, placeholder: SignInFlow.Copy.addressPlaceholder,
                            text: $address, submitLabel: .go, contentType: .URL, keyboardType: .URL,
                            id: "address", focus: $focusedControl)
            .accessibilityIdentifier("serverAddressField")
            Text(SignInFlow.Copy.addressHint)
                .font(.custom("DMMono-Regular", size: 19))
                .foregroundStyle(.white.opacity(0.4))
            Button(SignInFlow.Copy.connect) { submitAddress(kind) }
                .buttonStyle(OnboardingButtonStyle(role: .primary))
                .focused($focusedControl, equals: "connect")
                .disabled(address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityIdentifier("serverAddressConnectButton")
            backButton { go(to: .find(kind)) }
        }
        .frame(maxWidth: 720)
    }

    // MARK: - Jellyfin / Emby: sign in

    private func signInSection(_ server: SignInFlow.CheckedServer) -> some View {
        let showTiles = !server.users.isEmpty && !typingName
        let prefix = server.kind == .jellyfin ? "jellyfin" : "emby"
        return VStack(spacing: 20) {
            VStack(spacing: 6) {
                caption(SignInFlow.Copy.signInTo)
                Text(server.name.uppercased())
                    .font(.custom("DMMono-Medium", size: 34))
                    .foregroundStyle(OnboardingPalette.cyan)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                Text("\(server.kind.displayName.uppercased())  \(server.url)")
                    .font(.custom("DMMono-Regular", size: 18))
                    .foregroundStyle(.white.opacity(0.35))
                    .lineLimit(1)
            }

            if let message = flowMessage {
                Text(message)
                    .font(.custom("DMMono-Regular", size: 19))
                    .foregroundStyle(.white.opacity(0.55))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let error = appState.authError {
                Text(error.uppercased())
                    .font(.custom("DMMono-Medium", size: 22))
                    .foregroundStyle(OnboardingPalette.error)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if showTiles {
                caption(SignInFlow.Copy.whoIsWatching)
                userTiles(server)
            } else {
                OnboardingField(caption: SignInFlow.Copy.username, placeholder: SignInFlow.Copy.pressToType,
                                text: $username, submitLabel: .next, contentType: .username,
                                id: "username", focus: $focusedControl)
                .accessibilityIdentifier("\(prefix)UsernameField")
            }

            if !showTiles || pickedUser?.hasPassword == true {
                OnboardingField(caption: pickedUser.map { "PASSWORD FOR \($0.name.uppercased())" } ?? SignInFlow.Copy.password,
                                placeholder: SignInFlow.Copy.pressToType, text: $password, secure: true,
                                submitLabel: .go, contentType: .password,
                                id: "password", focus: $focusedControl) {
                    // Done on the keyboard signs in; Back moves to SIGN IN (keyboardClosed).
                    signIn(server)
                }
                .accessibilityIdentifier("\(prefix)PasswordField")

                Button(SignInFlow.Copy.signIn) { signIn(server) }
                    .buttonStyle(OnboardingButtonStyle(role: .primary))
                    .focused($focusedControl, equals: "signin")
                    .disabled(pickedUser == nil && username.trimmingCharacters(in: .whitespaces).isEmpty)
                    .accessibilityIdentifier("\(prefix)SignInButton")
            }

            if server.offersQuickConnect {
                Button(SignInFlow.Copy.useQuickConnect) { startQuickConnect(server) }
                    .buttonStyle(OnboardingButtonStyle(role: .secondary))
                    .focused($focusedControl, equals: "quick")
                    .accessibilityIdentifier("jellyfinQuickConnectButton")
            }

            backButton { go(to: .find(currentKind)) }
        }
        .frame(maxWidth: 720)
    }

    /// The server's own user list as tiles, three to a row, then SOMEONE ELSE. A user
    /// with no password signs in on the press; one with a password moves to the field.
    private func userTiles(_ server: SignInFlow.CheckedServer) -> some View {
        let users = Array(server.users.prefix(8))
        let rows = stride(from: 0, to: users.count + 1, by: 3).map { start in
            Array((users.map { Optional($0) } + [nil])[start..<min(start + 3, users.count + 1)])
        }
        return VStack(spacing: 16) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                HStack(spacing: 16) {
                    ForEach(Array(row.enumerated()), id: \.offset) { _, user in
                        if let user {
                            Button(user.name) {
                                pickedUser = user
                                username = user.name
                                password = ""
                                if user.hasPassword {
                                    focusSoon("password")
                                } else {
                                    signIn(server)
                                }
                            }
                            .buttonStyle(OnboardingButtonStyle(role: pickedUser == user ? .primary : .secondary, fontSize: 26))
                            .focused($focusedControl, equals: "user-\(user.id)")
                            .accessibilityIdentifier("userTile-\(user.name)")
                        } else {
                            Button(SignInFlow.Copy.someoneElse) {
                                pickedUser = nil
                                typingName = true
                                username = ""
                                focusSoon("username")
                            }
                            .buttonStyle(OnboardingButtonStyle(role: .secondary, fontSize: 22))
                            .focused($focusedControl, equals: "someone")
                            .accessibilityIdentifier("userTileSomeoneElse")
                        }
                    }
                }
            }
        }
    }

    // MARK: - Waiting states

    private var quickConnectSection: some View {
        let server: SignInFlow.CheckedServer? = { if case .signIn(let s) = screen { return s } else { return nil } }()
        return VStack(alignment: .center, spacing: 22) {
            stepTitle(SignInFlow.Copy.quickConnectTitle)
            Text(SignInFlow.Copy.quickConnectSteps)
                .font(.custom("DMMono-Regular", size: 22))
                .foregroundStyle(.white.opacity(0.6))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            Text(appState.jellyfinQuickConnectCode.isEmpty ? "------" : appState.jellyfinQuickConnectCode)
                .font(.custom("DMMono-Medium", size: 108))
                .foregroundStyle(.white)
                .kerning(16)
                .accessibilityIdentifier("quickConnectCode")

            WaitingIndicatorView(message: SignInFlow.Copy.waitingForApproval)
            if let server {
                Text("\(server.name.uppercased())  \(server.url)")
                    .font(.custom("DMMono-Regular", size: 18))
                    .foregroundStyle(.white.opacity(0.35))
                    .lineLimit(1)
            }

            // On a code screen the code is the thing to look at, so the buttons here light
            // up with an outline glow instead of the solid slab (quietFocus).
            Button(SignInFlow.Copy.usePassword) {
                usingQuickConnect = false
                appState.cancelPINAuth()
                focusSoon(server?.users.isEmpty == false ? "user-\(server!.users[0].id)" : "username")
            }
            .buttonStyle(OnboardingButtonStyle(role: .secondary, quietFocus: true))
            .focused($focusedControl, equals: "usePassword")
            .accessibilityIdentifier("quickConnectUsePasswordButton")
            .padding(.top, 10)

            backButton(quietFocus: true) {
                usingQuickConnect = false
                appState.cancelPINAuth()
                go(to: .find(currentKind))
            }
        }
        .frame(maxWidth: 760)
    }

    private var signingInSection: some View {
        VStack(spacing: 28) {
            WaitingIndicatorView(message: "SIGNING IN")
            cancelButton { appState.cancelPINAuth() }
        }
    }

    private func checkingSection(_ label: String) -> some View {
        VStack(spacing: 28) {
            WaitingIndicatorView(message: SignInFlow.Copy.connecting(label))
                .multilineTextAlignment(.center)
            cancelButton {
                flowToken += 1
                checkTask?.cancel()
                checkTask = nil
                checkingLabel = nil
            }
        }
        .frame(maxWidth: 720)
    }

    // MARK: - PIN display (Plex polling state)

    private var pinDisplaySection: some View {
        HStack(alignment: .center, spacing: 80) {

            // Left: instructions + PIN + status
            VStack(alignment: .leading, spacing: 24) {
                Text("GO TO plex.tv/link AND ENTER:")
                    .font(.custom("DMMono-Medium", size: 28))
                    .foregroundStyle(OnboardingPalette.cyan)

                Text(appState.pinCode.isEmpty ? "----" : appState.pinCode)
                    .font(.custom("DMMono-Medium", size: 108))
                    .foregroundStyle(.white)
                    .kerning(16)

                WaitingIndicatorView(message: appState.isDiscoveringServers
                    ? "FINDING YOUR SERVERS"
                    : appState.pinCode.isEmpty ? "CONNECTING TO PLEX.TV" : "WAITING FOR AUTHORIZATION")

                cancelButton(quietFocus: true) { appState.cancelPINAuth() }
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

    // MARK: - Pieces

    private func stepTitle(_ text: String) -> some View {
        Text(text)
            .font(.custom("DMMono-Medium", size: 34))
            .foregroundStyle(OnboardingPalette.cyan)
            .multilineTextAlignment(.center)
    }

    private func caption(_ text: String) -> some View {
        Text(text)
            .font(.custom("DMMono-Medium", size: 20))
            .tracking(2)
            .foregroundStyle(.white.opacity(0.45))
    }

    @ViewBuilder
    private var flowMessageView: some View {
        if let message = flowMessage {
            Text(message)
                .font(.custom("DMMono-Regular", size: 20))
                .foregroundStyle(OnboardingPalette.warning.opacity(0.95))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("signInFlowMessage")
        }
    }

    private func backButton(quietFocus: Bool = false, _ action: @escaping () -> Void) -> some View {
        Button(SignInFlow.Copy.back, action: action)
            .buttonStyle(OnboardingButtonStyle(role: .quiet, fullWidth: false, quietFocus: quietFocus))
            .focused($focusedControl, equals: "back")
            .padding(.top, 6)
    }

    private func cancelButton(quietFocus: Bool = false, _ action: @escaping () -> Void) -> some View {
        Button(SignInFlow.Copy.cancel, action: action)
            .buttonStyle(OnboardingButtonStyle(role: .quiet, fullWidth: false, quietFocus: quietFocus))
            .focused($focusedControl, equals: "cancel")
            .accessibilityIdentifier("signInCancelButton")
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
