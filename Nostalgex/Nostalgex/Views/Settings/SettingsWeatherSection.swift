import SwiftUI

/// WEATHER, under PLAYBACK & PICTURE (Trello I-016): LOCATION, UNITS and the channel's switch. The same three
/// settings as the web tuner's WEATHER row.
struct SettingsWeatherSection: View {
    @Environment(AppState.self) var appState
    let focus: FocusState<SettingsFocus?>.Binding
    @State private var weather = WeatherController.shared
    @State private var showLocation = false

    var body: some View {
        SettingsSectionHeader(
            title: "WEATHER",
            subtitle: "LOCAL WEATHER, CH \(WeatherEngine.channelNumber): current conditions, the forecast and radar"
        )
        .padding(.top, 20)

        SettingsToggleRow(
            title: "LOCATION",
            subtitle: weather.place == nil ? "Type a city or a postcode, then pick it from the matches" : "The forecast is for this place",
            detail: weather.place.map { p in p.code.map { "\(WeatherEngine.placeLabel(p)) (\($0))" } ?? WeatherEngine.placeLabel(p) } ?? "NOT SET",
            isOn: true,
            isFocused: isFocused("weather_location"),
            showToggle: false
        ) {
            showLocation = true
        }
        .settingsRow("weather_location", focus: focus)

        SettingsToggleRow(
            title: "UNITS",
            subtitle: unitsExplanation,
            detail: unitsLabel,
            isOn: true,
            isFocused: isFocused("weather_units"),
            showToggle: false
        ) {
            weather.cycleUnits()
        }
        .settingsRow("weather_units", focus: focus)
        .accessibilityValue(unitsLabel)

        SettingsToggleRow(
            title: "SHOW THE WEATHER CHANNEL",
            subtitle: "LOCAL WEATHER, channel \(WeatherEngine.channelNumber), in the guide",
            isOn: weather.channelOn,
            isFocused: isFocused("weather_channel")
        ) {
            weather.setChannelOn(!weather.channelOn)
            appState.applyWeatherChannelSetting()
        }
        .settingsRow("weather_channel", focus: focus)
        .fullScreenCover(isPresented: $showLocation) {
            WeatherLocationSheet()
        }
    }

    private func isFocused(_ id: String) -> Bool {
        focus.wrappedValue == .row(id)
    }

    private var unitsLabel: String {
        switch weather.unitsSetting {
        case "F": return "\u{00B0}F"
        case "C": return "\u{00B0}C"
        default: return "AUTO"
        }
    }

    private var unitsExplanation: String {
        if weather.unitsSetting == "auto" {
            return "Fahrenheit in the United States, Celsius everywhere else"
        }
        return weather.units == .F ? "Fahrenheit, miles per hour and inches" : "Celsius, kilometres per hour and millimetres"
    }
}

/// Type a city or a postcode, pick it from the matches. The place list is GeoNames' (CC BY 4.0), read from
/// nostalgex.app/weather/places/ a few kilobytes at a time; nothing about the viewer is sent with it.
struct WeatherLocationSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var weather = WeatherController.shared
    @State private var query = ""
    @State private var results: [WeatherEngine.Place] = []
    @State private var hint = "Type at least 2 letters of a city, or a postcode."
    @State private var searchTask: Task<Void, Never>?
    @FocusState private var focusedID: String?

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color(red: 0.04, green: 0.04, blue: 0.10), Color(red: 0.05, green: 0.05, blue: 0.12)],
                startPoint: .topLeading, endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            VStack(alignment: .leading, spacing: 16) {
                Text("WEATHER LOCATION")
                    .font(SettingsFont.heading)
                    .foregroundStyle(Color.nxText2)

                Text(weather.place.map { "Now: \(WeatherEngine.placeLabel($0))" } ?? "Type a city or a postcode, then pick it from the matches.")
                    .font(NXFont.captionRegular)
                    .foregroundStyle(Color.nxText2)

                TextField("CITY OR POSTCODE", text: $query)
                    .font(SettingsFont.bodyMedium)
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()
                    .focused($focusedID, equals: "field")
                    .onChange(of: query) { _, value in scheduleSearch(value) }
                    .onSubmit { scheduleSearch(query, delay: 0) }
                    .accessibilityIdentifier("weatherLocationField")

                Text(hint)
                    .font(NXFont.captionRegular)
                    .foregroundStyle(Color.nxText2)
                    .accessibilityIdentifier("weatherLocationHint")

                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: 5) {
                        ForEach(Array(results.enumerated()), id: \.offset) { i, place in
                            Button {
                                weather.pick(place)
                                dismiss()
                            } label: {
                                Text(place.label ?? WeatherEngine.placeLabel(place))
                                    .font(SettingsFont.bodyMedium)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(15)
                            }
                            .focused($focusedID, equals: "result-\(i)")
                            .accessibilityIdentifier("weatherResult-\(i)")
                        }
                        if weather.place != nil {
                            Button {
                                weather.clearPlace()
                                dismiss()
                            } label: {
                                Text("REMOVE LOCATION")
                                    .font(SettingsFont.bodyMedium)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(15)
                            }
                            .focused($focusedID, equals: "remove")
                        }
                    }
                }

                Text("Place names from GeoNames (geonames.org), CC BY 4.0. To get the forecast, the place you pick is sent, rounded to about a kilometre, to nostalgex.app and on to MET Norway.")
                    .font(NXFont.captionRegular)
                    .foregroundStyle(Color.nxText2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 120)
            .padding(.vertical, 80)
            .frame(maxWidth: 1400, alignment: .leading)
        }
        .onAppear { focusedID = "field" }
    }

    private func scheduleSearch(_ value: String, delay: Int = 250) {
        searchTask?.cancel()
        let q = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard q.count >= 2 else {
            results = []
            hint = "Type at least 2 letters of a city, or a postcode."
            return
        }
        searchTask = Task {
            if delay > 0 { try? await Task.sleep(for: .milliseconds(delay)) }
            guard !Task.isCancelled else { return }
            hint = "LOOKING..."
            let r = await weather.search(q)
            guard !Task.isCancelled else { return }
            results = r.places
            if r.places.isEmpty {
                hint = r.hint.isEmpty ? "NO MATCH. TRY THE CITY NAME OR A POSTCODE." : r.hint
            } else {
                hint = "\(r.places.count) \(r.places.count == 1 ? "MATCH" : "MATCHES"). PICK ONE."
            }
        }
    }
}

/// ABOUT, WEATHER CREDITS: who the weather channel's data comes from, with the credit their licences ask for.
enum WeatherCredits {
    struct Credit { let id: String; let title: String; let subtitle: String; let address: String }
    static let all: [Credit] = [
        Credit(id: "met", title: "MET NORWAY",
               subtitle: "Weather data from MET Norway, CC BY 4.0. Forecasts rearranged for display.",
               address: "api.met.no"),
        Credit(id: "geonames", title: "GEONAMES",
               subtitle: "Place names from GeoNames, CC BY 4.0.",
               address: "geonames.org"),
        Credit(id: "naturalearth", title: "NATURAL EARTH",
               subtitle: "Map outlines under the radar. Public domain.",
               address: "naturalearthdata.com"),
        Credit(id: "noaa", title: "NOAA NATIONAL WEATHER SERVICE",
               subtitle: "Radar for the United States, MRMS composites. Public domain.",
               address: "weather.gov"),
        Credit(id: "eccc", title: "ENVIRONMENT CANADA",
               subtitle: "Radar for Canada. Data Source: Environment and Climate Change Canada.",
               address: "weather.gc.ca"),
        Credit(id: "dwd", title: "DEUTSCHER WETTERDIENST",
               subtitle: "Radar for Germany. Datenbasis: Deutscher Wetterdienst, Rasterdaten bildlich wiedergegeben. CC BY 4.0.",
               address: "dwd.de"),
        Credit(id: "music", title: "WEATHER MUSIC",
               subtitle: "An original loop written for Nostalgex, played with the FluidR3_GM sound set (MIT).",
               address: "github.com/chadMueller/Nostalgex"),
    ]
}
