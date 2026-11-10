import XCTest

/// Shared helpers for the sign-in tours: every remote press goes through `press` so the
/// tour can count them, and every screenshot goes to NOSTALGEX_SHOTS_DIR when it is set
/// (forward it with TEST_RUNNER_NOSTALGEX_SHOTS_DIR) as well as into the result bundle.
///
/// Press convention: a direction or Select is one press. Typing into a field is counted
/// as two presses (Select to open the keyboard, Back to close it) plus the characters,
/// which are not counted.
class SignInTourCase: XCTestCase {
    var presses = 0
    var lines: [String] = []
    var app: XCUIApplication!

    var env: [String: String] { ProcessInfo.processInfo.environment }
    var shotsDir: String? { env["NOSTALGEX_SHOTS_DIR"] }

    override func setUp() {
        continueAfterFailure = false
        app = isolatedApp()
    }

    func launch(_ arguments: [String] = []) {
        app.launchArguments = arguments
        app.launch()
        presses = 0
    }

    func focusedDescription() -> String {
        let element = app.descendants(matching: .any)
            .matching(NSPredicate(format: "hasFocus == true")).firstMatch
        guard element.exists else { return "nothing" }
        let text = element.label.isEmpty ? element.identifier : element.label
        return text.isEmpty ? "(unlabelled \(element.elementType.rawValue))" : text
    }

    func press(_ button: XCUIRemote.Button, _ why: String = "") {
        XCUIRemote.shared.press(button)
        presses += 1
        usleep(500_000)
        note("press \(name(of: button))\(why.isEmpty ? "" : " (\(why))") -> focus: \(focusedDescription())")
    }

    /// Opens the focused field's keyboard, types, and closes it with Back (2 presses).
    func typeIntoFocusedField(_ text: String, secret: Bool = false) {
        press(.select, "open keyboard")
        usleep(800_000)
        app.typeText(text)
        usleep(400_000)
        note("typed \(secret ? "<\(text.count) characters>" : text)")
        if app.keyboards.count > 0 || focusedDescription() == "Keyboard" {
            press(.menu, "close keyboard")
        }
        usleep(500_000)
    }

    func moveFocus(to element: XCUIElement, _ direction: XCUIRemote.Button, limit: Int = 12) {
        var n = 0
        while !element.hasFocus && n < limit {
            press(direction)
            n += 1
        }
        XCTAssertTrue(element.hasFocus, "could not focus \(element.label) after \(n) presses")
    }

    func shot(_ name: String) {
        usleep(700_000)
        let png = XCUIScreen.main.screenshot().pngRepresentation
        if let dir = shotsDir {
            try? png.write(to: URL(fileURLWithPath: dir).appendingPathComponent(name + ".png"))
        }
        let attachment = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        note("screenshot \(name)")
    }

    func note(_ s: String) {
        let line = "[\(presses)] \(s)"
        lines.append(line)
        print("[TOUR] \(line)")
    }

    func writeLog(_ name: String) {
        guard let dir = shotsDir else { return }
        try? lines.joined(separator: "\n").write(toFile: "\(dir)/\(name).log", atomically: true, encoding: .utf8)
    }

    /// Sign-in is over when the library has loaded: the guide (its settings control), or,
    /// on a library too small to fill a channel, the NO CHANNELS FOUND screen.
    func waitForGuide(timeout: TimeInterval = 240) -> Bool {
        let guide = app.descendants(matching: .any).matching(NSPredicate(
            format: "identifier == 'tunerSettingsButton' OR identifier == 'tunerSidebarSettings' OR label == 'NO CHANNELS FOUND'")).firstMatch
        let start = Date()
        while Date().timeIntervalSince(start) < timeout {
            if guide.exists {
                let what = guide.label == "NO CHANNELS FOUND" ? "library loaded (NO CHANNELS FOUND)" : "guide built"
                note("\(what) \(Int(Date().timeIntervalSince(start))) s after the last press")
                return true
            }
            sleep(2)
        }
        shot("debug-no-guide-\(name.filter { $0.isLetter || $0.isNumber })")
        return false
    }

    /// Reads a code shown big on screen: the first static text of `length` characters
    /// made only of capital letters and digits.
    func codeOnScreen(length: Int, timeout: TimeInterval = 20) -> String? {
        let start = Date()
        while Date().timeIntervalSince(start) < timeout {
            for text in app.staticTexts.allElementsBoundByIndex {
                let label = text.label
                if label.count == length,
                   label.allSatisfy({ ($0.isUppercase && $0.isLetter) || $0.isNumber }) { return label }
            }
            sleep(1)
        }
        return nil
    }

    /// Approves a Jellyfin Quick Connect code for the lab user, as the user would on
    /// their phone. Needs NX_JF_BASE, NX_JF_KEY and NX_JF_USERID.
    func approveJellyfinQuickConnect(code: String) -> Bool {
        guard let base = env["NX_JF_BASE"], let key = env["NX_JF_KEY"], let user = env["NX_JF_USERID"],
              let url = URL(string: "\(base)/QuickConnect/Authorize?code=\(code)&userId=\(user)") else { return false }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("MediaBrowser Token=\"\(key)\"", forHTTPHeaderField: "Authorization")
        let done = expectation(description: "authorize")
        var ok = false
        URLSession.shared.dataTask(with: request) { _, response, _ in
            ok = (response as? HTTPURLResponse)?.statusCode == 200
            done.fulfill()
        }.resume()
        wait(for: [done], timeout: 15)
        note("approved Quick Connect code from outside the TV: \(ok)")
        return ok
    }

    /// Links a plex.tv PIN to the account behind NX_PLEX_TOKEN, as the user would at
    /// plex.tv/link.
    func linkPlexPIN(code: String) -> Bool {
        guard let token = env["NX_PLEX_TOKEN"], let client = env["NX_PLEX_CLIENT"],
              let url = URL(string: "https://plex.tv/api/v2/pins/link.json") else { return false }
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue(token, forHTTPHeaderField: "X-Plex-Token")
        request.setValue(client, forHTTPHeaderField: "X-Plex-Client-Identifier")
        // plex.tv refuses the link (403) unless it comes from the web app, as plex.tv/link does.
        request.setValue("Plex Web", forHTTPHeaderField: "X-Plex-Product")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = "code=\(code)".data(using: .utf8)
        let done = expectation(description: "link")
        var ok = false
        URLSession.shared.dataTask(with: request) { _, response, _ in
            ok = (200...299).contains((response as? HTTPURLResponse)?.statusCode ?? 0)
            done.fulfill()
        }.resume()
        wait(for: [done], timeout: 20)
        note("linked the Plex code from outside the TV: \(ok)")
        return ok
    }

    private func name(of button: XCUIRemote.Button) -> String {
        switch button {
        case .up: return "UP"
        case .down: return "DOWN"
        case .left: return "LEFT"
        case .right: return "RIGHT"
        case .select: return "SELECT"
        case .menu: return "BACK"
        case .playPause: return "PLAY"
        case .home: return "HOME"
        @unknown default: return "?"
        }
    }
}
