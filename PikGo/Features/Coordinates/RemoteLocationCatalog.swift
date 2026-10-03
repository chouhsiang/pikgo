import Foundation
import CoreLocation
import Combine

struct LocationCatalogPlace: Identifiable, Hashable {
    let id: String
    let name: String
    let coordinate: CLLocationCoordinate2D

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    static func == (lhs: LocationCatalogPlace, rhs: LocationCatalogPlace) -> Bool {
        lhs.id == rhs.id
    }
}

struct LocationCatalogSection: Identifiable, Hashable {
    let id: String
    let title: String
    let places: [LocationCatalogPlace]
}

struct LocationCatalogCity: Identifiable, Hashable {
    let id: String
    let name: String
    let timeZoneIdentifier: String
    let coordinate: CLLocationCoordinate2D

    var asPlace: LocationCatalogPlace {
        LocationCatalogPlace(id: id, name: name, coordinate: coordinate)
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    static func == (lhs: LocationCatalogCity, rhs: LocationCatalogCity) -> Bool {
        lhs.id == rhs.id
    }
}

struct LocationCatalogCountry: Identifiable, Hashable {
    let id: String
    let name: String
    let flag: String
    let cities: [LocationCatalogCity]

    var representativeTimeZone: String {
        cities.first?.timeZoneIdentifier ?? TimeZone.current.identifier
    }

    var isSingleCity: Bool {
        cities.count == 1
    }

    var matchesCurrentTimeZone: Bool {
        let current = TimeZone.current.identifier
        return cities.contains { $0.timeZoneIdentifier == current }
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    static func == (lhs: LocationCatalogCountry, rhs: LocationCatalogCountry) -> Bool {
        lhs.id == rhs.id
    }
}

@MainActor
final class RemoteLocationCatalog: ObservableObject {
    static let shared = RemoteLocationCatalog()
    static let decorURL = URL(string: "https://chouhsiang.github.io/mylocation/decor.json")!
    static let cityURL = URL(string: "https://chouhsiang.github.io/mylocation/city.json")!

    @Published private(set) var sections: [LocationCatalogSection] = []
    @Published private(set) var countries: [LocationCatalogCountry] = []
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var lastUpdated: Date?

    var isEmpty: Bool {
        sections.isEmpty && countries.isEmpty
    }

    private init() {
        if let cached = Self.loadCache(named: "decor.json", parse: Self.parseDecor) {
            sections = cached
        }
        if let cached = Self.loadCache(named: "city.json", parse: Self.parseCities) {
            countries = cached
        }
    }

    func refresh() async {
        guard !isLoading else { return }
        isLoading = true
        if isEmpty {
            errorMessage = nil
        }

        async let decorResult = fetchData(from: Self.decorURL)
        async let cityResult = fetchData(from: Self.cityURL)
        let (decorData, cityData) = await (decorResult, cityResult)

        var errors: [String] = []

        if let decorData, let parsed = try? Self.parseDecor(decorData), !parsed.isEmpty {
            sections = parsed
            Self.saveCache(named: "decor.json", data: decorData)
        } else if sections.isEmpty {
            errors.append("飾品")
        }

        if let cityData, let parsed = try? Self.parseCities(cityData), !parsed.isEmpty {
            countries = parsed
            Self.saveCache(named: "city.json", data: cityData)
        } else if countries.isEmpty {
            errors.append("城市")
        }

        if errors.isEmpty {
            lastUpdated = Date()
            errorMessage = nil
        } else if isEmpty {
            errorMessage = "無法載入座標清單，請確認網路後再試。"
        } else {
            errorMessage = "無法更新\(errors.joined(separator: "、"))清單，先顯示上次載入的內容。"
        }

        isLoading = false
    }

    private func fetchData(from url: URL) async -> Data? {
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 20
        if var components = URLComponents(url: url, resolvingAgainstBaseURL: false) {
            components.queryItems = [URLQueryItem(name: "t", value: String(Int(Date().timeIntervalSince1970)))]
            request.url = components.url ?? url
        }
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse,
              (200...299).contains(http.statusCode) else {
            return nil
        }
        return data
    }

    private static func parseDecor(_ data: Data) throws -> [LocationCatalogSection] {
        let groups = try JSONDecoder().decode([RemoteDecorSection].self, from: data)
        return groups.compactMap { group in
            let title = group.section.trimmingCharacters(in: .whitespacesAndNewlines)
            let places = group.items.compactMap { item -> LocationCatalogPlace? in
                let name = item.name.trimmingCharacters(in: .whitespacesAndNewlines)
                let coordinate = CLLocationCoordinate2D(latitude: item.lat, longitude: item.lng)
                guard !name.isEmpty, CLLocationCoordinate2DIsValid(coordinate) else {
                    return nil
                }
                return LocationCatalogPlace(
                    id: "decor-\(title)-\(name)-\(item.lat)-\(item.lng)",
                    name: name,
                    coordinate: coordinate
                )
            }
            guard !title.isEmpty, !places.isEmpty else { return nil }
            return LocationCatalogSection(id: title, title: title, places: places)
        }
    }

    private static func parseCities(_ data: Data) throws -> [LocationCatalogCountry] {
        let groups = try JSONDecoder().decode([RemoteCountry].self, from: data)
        let countries = groups.compactMap { group -> LocationCatalogCountry? in
            let name = group.name.trimmingCharacters(in: .whitespacesAndNewlines)
            let cities = group.cities.compactMap { item -> LocationCatalogCity? in
                let cityName = item.sub.trimmingCharacters(in: .whitespacesAndNewlines)
                let coordinate = CLLocationCoordinate2D(latitude: item.lat, longitude: item.lng)
                guard !cityName.isEmpty, CLLocationCoordinate2DIsValid(coordinate) else {
                    return nil
                }
                return LocationCatalogCity(
                    id: "city-\(name)-\(cityName)-\(item.lat)-\(item.lng)",
                    name: cityName,
                    timeZoneIdentifier: item.tz,
                    coordinate: coordinate
                )
            }
            guard !name.isEmpty, !cities.isEmpty else { return nil }
            return LocationCatalogCountry(
                id: "country-\(name)",
                name: name,
                flag: group.flag.trimmingCharacters(in: .whitespacesAndNewlines),
                cities: cities
            )
        }
        return countries.sorted { lhs, rhs in
            LocationTimeDisplay.utcOffsetMinutes(lhs.representativeTimeZone)
                < LocationTimeDisplay.utcOffsetMinutes(rhs.representativeTimeZone)
        }
    }

    private static func cacheDirectory() -> URL {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LocationCatalog", isDirectory: true)
    }

    private static func loadCache<T>(named fileName: String, parse: (Data) throws -> T) -> T? {
        let url = cacheDirectory().appendingPathComponent(fileName)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? parse(data)
    }

    private static func saveCache(named fileName: String, data: Data) {
        let directory = cacheDirectory()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: directory.appendingPathComponent(fileName), options: .atomic)
    }
}

enum LocationTimeDisplay {
    static func utcOffsetMinutes(_ identifier: String, at date: Date = Date()) -> Int {
        let timeZone = TimeZone(identifier: identifier) ?? .current
        return timeZone.secondsFromGMT(for: date) / 60
    }

    static func localTimeText(_ identifier: String, at date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_Hant_TW")
        formatter.timeZone = TimeZone(identifier: identifier) ?? .current
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }

    static func isDaytime(_ identifier: String, at date: Date) -> Bool {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: identifier) ?? .current
        let hour = calendar.component(.hour, from: date)
        return hour >= 5 && hour < 18
    }

    static func offsetText(from identifier: String, at date: Date = Date()) -> String {
        let minutes = utcOffsetMinutes(identifier, at: date) - utcOffsetMinutes(TimeZone.current.identifier, at: date)
        if minutes == 0 {
            return "±0h"
        }
        let sign = minutes > 0 ? "+" : "-"
        let absolute = abs(minutes)
        let hours = absolute / 60
        let remain = absolute % 60
        if remain == 0 {
            return "\(sign)\(hours)h"
        }
        return String(format: "%@%d:%02dh", sign, hours, remain)
    }
}

private struct RemoteDecorSection: Decodable {
    let section: String
    let items: [RemoteDecorPlace]
}

private struct RemoteDecorPlace: Decodable {
    let name: String
    let lat: Double
    let lng: Double
}

private struct RemoteCountry: Decodable {
    let name: String
    let flag: String
    let cities: [RemoteCity]
}

private struct RemoteCity: Decodable {
    let sub: String
    let tz: String
    let lat: Double
    let lng: Double
}
