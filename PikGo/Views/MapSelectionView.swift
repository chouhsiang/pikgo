//
//  MapSelectionView.swift
//  PikGo
//
//  Created by Stephen on 11/3/25.
//

import SwiftUI
import MapKit
import UIKit
import QuartzCore
import UniformTypeIdentifiers

private struct CoordinateSnapshot: Equatable {
    let latitude: Double
    let longitude: Double

    init(_ coordinate: CLLocationCoordinate2D) {
        latitude = coordinate.latitude
        longitude = coordinate.longitude
    }

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}

private struct RouteSearchSelection: Equatable {
    let title: String
    let coordinate: CLLocationCoordinate2D

    static func == (lhs: RouteSearchSelection, rhs: RouteSearchSelection) -> Bool {
        lhs.title == rhs.title &&
        CoordinateSnapshot(lhs.coordinate) == CoordinateSnapshot(rhs.coordinate)
    }
}

private enum RouteSearchField {
    case start
    case end
}

private struct RouteSimulationPlan {
    let displayCoordinates: [CLLocationCoordinate2D]
    let distance: CLLocationDistance
    let expectedTravelTime: TimeInterval
}

private struct RouteModePreview {
    let distance: CLLocationDistance
    let displayCoordinates: [CLLocationCoordinate2D]
    var isDirectPath = false

    func travelTime(kilometersPerHour: Double = RouteSimulationSpeed.kilometersPerHour) -> TimeInterval {
        let metersPerSecond = max(kilometersPerHour, RouteSimulationSpeed.minimumKilometersPerHour) / 3.6
        return distance / metersPerSecond
    }
}

private enum RouteSimulationDefaults {
    static let pathSamplingDistance: CLLocationDistance = 10
    static let playbackTickInterval: TimeInterval = 0.5
    static func kilometersPerHour(for mode: RouteNavigationMode) -> Double {
        RouteSimulationSpeed.kilometersPerHour(for: mode)
    }

    static func metersPerSecond(for mode: RouteNavigationMode) -> CLLocationSpeed {
        RouteSimulationSpeed.metersPerSecond(for: mode)
    }

    static var fixedSpeedKilometersPerHour: Double { RouteSimulationSpeed.kilometersPerHour }
    static var fixedSpeedMetersPerSecond: CLLocationSpeed { RouteSimulationSpeed.metersPerSecond }
    static let navigationCameraDistance: CLLocationDistance = 880
    static let navigationCameraPitch: Double = 50
    static let navigationCenterOffset: CLLocationDistance = 120
    static let navigationHeadingSmoothingTime: TimeInterval = 0.22
    static let airplaneDisplayPointCount = 160
    static let airplaneMaxPlaybackSamples = 2400
}

private struct RoutePlaybackSample {
    let coordinate: CLLocationCoordinate2D
    let delayFromPrevious: TimeInterval
}

private struct OpenStreetMapWay {
    let geometry: [CLLocationCoordinate2D]
    let speedLimitMetersPerSecond: CLLocationSpeed
}

private enum OpenStreetMapSpeedLimitService {
    static let endpoint = URL(string: "https://overpass-api.de/api/interpreter")!
    static let copyrightURL = URL(string: "https://www.openstreetmap.org/copyright")!
    static let boundingBoxPaddingDegrees = 0.0015
    static let nearestWayThreshold: CLLocationDistance = 40
}

private struct OverpassResponse: Decodable {
    let elements: [Element]

    struct Element: Decodable {
        let tags: [String: String]?
        let geometry: [Coordinate]?
    }

    struct Coordinate: Decodable {
        let lat: Double
        let lon: Double
    }
}

private extension MKPolyline {
    var coordinateArray: [CLLocationCoordinate2D] {
        var coordinates = [CLLocationCoordinate2D](
            repeating: CLLocationCoordinate2D(latitude: 0, longitude: 0),
            count: pointCount
        )
        getCoordinates(&coordinates, range: NSRange(location: 0, length: pointCount))
        return coordinates
    }
}

private func interpolateCoordinate(
    from start: CLLocationCoordinate2D,
    to end: CLLocationCoordinate2D,
    fraction: Double
) -> CLLocationCoordinate2D {
    CLLocationCoordinate2D(
        latitude: start.latitude + ((end.latitude - start.latitude) * fraction),
        longitude: start.longitude + ((end.longitude - start.longitude) * fraction)
    )
}

private func interpolateGeodesic(
    from start: CLLocationCoordinate2D,
    to end: CLLocationCoordinate2D,
    fraction: Double
) -> CLLocationCoordinate2D {
    let clamped = min(max(fraction, 0), 1)
    let lat1 = start.latitude * .pi / 180
    let lon1 = start.longitude * .pi / 180
    let lat2 = end.latitude * .pi / 180
    let lon2 = end.longitude * .pi / 180
    let delta = 2 * asin(sqrt(
        pow(sin((lat1 - lat2) / 2), 2) +
        cos(lat1) * cos(lat2) * pow(sin((lon1 - lon2) / 2), 2)
    ))
    guard delta > 1e-12, sin(delta).isFinite, abs(sin(delta)) > 1e-12 else {
        return interpolateCoordinate(from: start, to: end, fraction: clamped)
    }

    let a = sin((1 - clamped) * delta) / sin(delta)
    let b = sin(clamped * delta) / sin(delta)
    let x = a * cos(lat1) * cos(lon1) + b * cos(lat2) * cos(lon2)
    let y = a * cos(lat1) * sin(lon1) + b * cos(lat2) * sin(lon2)
    let z = a * sin(lat1) + b * sin(lat2)
    return CLLocationCoordinate2D(
        latitude: atan2(z, sqrt(x * x + y * y)) * 180 / .pi,
        longitude: atan2(y, x) * 180 / .pi
    )
}

private func geodesicCoordinates(
    from start: CLLocationCoordinate2D,
    to end: CLLocationCoordinate2D,
    pointCount: Int
) -> [CLLocationCoordinate2D] {
    let count = max(pointCount, 2)
    return (0..<count).map { index in
        interpolateGeodesic(from: start, to: end, fraction: Double(index) / Double(count - 1))
    }
}

private func buildDirectPlaybackSamples(
    from start: CLLocationCoordinate2D,
    to end: CLLocationCoordinate2D,
    speedMetersPerSecond: CLLocationSpeed
) -> [RoutePlaybackSample] {
    let distance = CLLocation(latitude: start.latitude, longitude: start.longitude)
        .distance(from: CLLocation(latitude: end.latitude, longitude: end.longitude))
    guard distance > 0, speedMetersPerSecond > 0 else {
        return [RoutePlaybackSample(coordinate: start, delayFromPrevious: 0)]
    }

    let travelTime = distance / speedMetersPerSecond
    let sampleCount = min(
        RouteSimulationDefaults.airplaneMaxPlaybackSamples,
        max(2, Int(ceil(travelTime / RouteSimulationDefaults.playbackTickInterval)) + 1)
    )
    let stepDelay = travelTime / Double(sampleCount - 1)
    return (0..<sampleCount).map { index in
        RoutePlaybackSample(
            coordinate: interpolateGeodesic(
                from: start,
                to: end,
                fraction: Double(index) / Double(sampleCount - 1)
            ),
            delayFromPrevious: index == 0 ? 0 : stepDelay
        )
    }
}

private func formatRouteTravelTime(_ interval: TimeInterval) -> String {
    let minutes = max(1, Int((interval / 60).rounded()))
    if minutes < 60 {
        return "\(minutes)分鐘"
    }
    let hours = minutes / 60
    let remain = minutes % 60
    if remain == 0 {
        return "\(hours)小時"
    }
    return "\(hours)小時\(remain)分"
}

private func formatRouteDistance(_ distance: CLLocationDistance) -> String {
    if distance >= 1000 {
        let kilometers = distance / 1000
        if kilometers >= 10 {
            return String(format: "%.0f公里", kilometers)
        }
        return String(format: "%.1f公里", kilometers)
    }
    return String(format: "%.0f公尺", distance)
}

private func interpolateHeading(
    from start: CLLocationDirection,
    to end: CLLocationDirection,
    fraction: Double
) -> CLLocationDirection {
    var delta = end - start
    while delta > 180 { delta -= 360 }
    while delta < -180 { delta += 360 }
    return (start + (delta * fraction) + 360).truncatingRemainder(dividingBy: 360)
}

private func playbackProgress(
    in samples: [RoutePlaybackSample],
    elapsed: TimeInterval
) -> (coordinate: CLLocationCoordinate2D, index: Int)? {
    guard let first = samples.first else { return nil }
    if samples.count == 1 || elapsed <= 0 {
        return (first.coordinate, 0)
    }

    var remaining = elapsed
    for index in 1..<samples.count {
        let delay = max(samples[index].delayFromPrevious, 0)
        if remaining <= delay {
            let fraction = delay > 0 ? remaining / delay : 1
            return (
                interpolateCoordinate(
                    from: samples[index - 1].coordinate,
                    to: samples[index].coordinate,
                    fraction: fraction
                ),
                index - 1
            )
        }
        remaining -= delay
    }

    return (samples[samples.count - 1].coordinate, samples.count - 1)
}

private func polylineTangentHeading(
    in samples: [RoutePlaybackSample],
    elapsed: TimeInterval
) -> CLLocationDirection? {
    guard samples.count > 1, let progress = playbackProgress(in: samples, elapsed: elapsed) else {
        return nil
    }

    var index = progress.index
    while index < samples.count - 1 {
        let start = samples[index].coordinate
        let end = samples[index + 1].coordinate
        let length = CLLocation(latitude: start.latitude, longitude: start.longitude)
            .distance(from: CLLocation(latitude: end.latitude, longitude: end.longitude))
        if length >= 2 {
            return heading(from: start, to: end)
        }
        index += 1
    }

    return heading(
        from: samples[samples.count - 2].coordinate,
        to: samples[samples.count - 1].coordinate
    )
}

private func sampledRouteCoordinates(
    from coordinates: [CLLocationCoordinate2D],
    targetDistance: CLLocationDistance
) -> [CLLocationCoordinate2D] {
    guard coordinates.count > 1 else { return coordinates }

    var sampled = [coordinates[0]]
    for (start, end) in zip(coordinates, coordinates.dropFirst()) {
        let distance = CLLocation(latitude: start.latitude, longitude: start.longitude)
            .distance(from: CLLocation(latitude: end.latitude, longitude: end.longitude))
        let segmentCount = max(1, Int(ceil(distance / targetDistance)))
        for index in 1...segmentCount {
            let point = interpolateCoordinate(
                from: start,
                to: end,
                fraction: Double(index) / Double(segmentCount)
            )
            if sampled.last.map(CoordinateSnapshot.init) != CoordinateSnapshot(point) {
                sampled.append(point)
            }
        }
    }

    return sampled
}

private func heading(from start: CLLocationCoordinate2D, to end: CLLocationCoordinate2D) -> CLLocationDirection {
    let lat1 = start.latitude * .pi / 180
    let lat2 = end.latitude * .pi / 180
    let dLon = (end.longitude - start.longitude) * .pi / 180
    let y = sin(dLon) * cos(lat2)
    let x = cos(lat1) * sin(lat2) - sin(lat1) * cos(lat2) * cos(dLon)
    return (atan2(y, x) * 180 / .pi + 360).truncatingRemainder(dividingBy: 360)
}

private func coordinateByMoving(
    _ start: CLLocationCoordinate2D,
    distance: CLLocationDistance,
    heading: CLLocationDirection
) -> CLLocationCoordinate2D {
    let earthRadius: CLLocationDistance = 6_371_000
    let angularDistance = distance / earthRadius
    let bearing = heading * .pi / 180
    let lat1 = start.latitude * .pi / 180
    let lon1 = start.longitude * .pi / 180
    let lat2 = asin(sin(lat1) * cos(angularDistance) + cos(lat1) * sin(angularDistance) * cos(bearing))
    let lon2 = lon1 + atan2(
        sin(bearing) * sin(angularDistance) * cos(lat1),
        cos(angularDistance) - sin(lat1) * sin(lat2)
    )
    return CLLocationCoordinate2D(latitude: lat2 * 180 / .pi, longitude: lon2 * 180 / .pi)
}

private func midpointCoordinate(
    from start: CLLocationCoordinate2D,
    to end: CLLocationCoordinate2D
) -> CLLocationCoordinate2D {
    interpolateCoordinate(from: start, to: end, fraction: 0.5)
}

private func distanceAlong(_ coordinates: [CLLocationCoordinate2D]) -> CLLocationDistance {
    zip(coordinates, coordinates.dropFirst()).reduce(0) { total, pair in
        total + CLLocation(latitude: pair.0.latitude, longitude: pair.0.longitude)
            .distance(from: CLLocation(latitude: pair.1.latitude, longitude: pair.1.longitude))
    }
}

private func distanceFromPoint(
    _ point: MKMapPoint,
    toSegmentFrom start: MKMapPoint,
    to end: MKMapPoint
) -> CLLocationDistance {
    let dx = end.x - start.x
    let dy = end.y - start.y

    guard dx != 0 || dy != 0 else {
        return point.distance(to: start)
    }

    let projection = max(0, min(1, ((point.x - start.x) * dx + (point.y - start.y) * dy) / ((dx * dx) + (dy * dy))))
    let projectedPoint = MKMapPoint(
        x: start.x + (dx * projection),
        y: start.y + (dy * projection)
    )
    return point.distance(to: projectedPoint)
}

private func parseSpeedLimitMetersPerSecond(from rawValue: String) -> CLLocationSpeed? {
    let normalized = rawValue
        .lowercased()
        .split(separator: ";")
        .first?
        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

    guard !normalized.isEmpty else { return nil }
    guard normalized != "none",
          normalized != "signals",
          normalized != "implicit",
          normalized != "walk" else {
        return nil
    }

    let scanner = Scanner(string: normalized)
    guard let numericValue = scanner.scanDouble() else { return nil }

    if normalized.contains("mph") {
        return numericValue * 0.44704
    }
    if normalized.contains("knot") {
        return numericValue * 0.514444
    }

    return numericValue / 3.6
}

private func speedLimitMetersPerSecond(from tags: [String: String]) -> CLLocationSpeed? {
    if let maxspeed = tags["maxspeed"],
       let parsed = parseSpeedLimitMetersPerSecond(from: maxspeed) {
        return parsed
    }

    let directionalValues = [
        tags["maxspeed:forward"],
        tags["maxspeed:backward"]
    ]
        .compactMap { $0 }
        .compactMap(parseSpeedLimitMetersPerSecond(from:))

    guard !directionalValues.isEmpty else { return nil }
    return directionalValues.min()
}

private func overpassQuery(for coordinates: [CLLocationCoordinate2D]) -> String? {
    guard let first = coordinates.first else { return nil }

    var minLatitude = first.latitude
    var maxLatitude = first.latitude
    var minLongitude = first.longitude
    var maxLongitude = first.longitude

    for coordinate in coordinates.dropFirst() {
        minLatitude = min(minLatitude, coordinate.latitude)
        maxLatitude = max(maxLatitude, coordinate.latitude)
        minLongitude = min(minLongitude, coordinate.longitude)
        maxLongitude = max(maxLongitude, coordinate.longitude)
    }

    let padding = OpenStreetMapSpeedLimitService.boundingBoxPaddingDegrees
    let south = minLatitude - padding
    let west = minLongitude - padding
    let north = maxLatitude + padding
    let east = maxLongitude + padding

    let bbox = String(format: "%.6f,%.6f,%.6f,%.6f", south, west, north, east)

    return """
    [out:json][timeout:20];
    (
      way(\(bbox))[highway][maxspeed];
      way(\(bbox))[highway]["maxspeed:forward"];
      way(\(bbox))[highway]["maxspeed:backward"];
    );
    out tags geom;
    """
}

private func fetchOpenStreetMapWays(for coordinates: [CLLocationCoordinate2D]) async throws -> [OpenStreetMapWay] {
    guard let query = overpassQuery(for: coordinates) else { return [] }

    var components = URLComponents(url: OpenStreetMapSpeedLimitService.endpoint, resolvingAgainstBaseURL: false)
    components?.queryItems = [URLQueryItem(name: "data", value: query)]
    guard let url = components?.url else { return [] }

    let (data, response) = try await URLSession.shared.data(from: url)

    if let httpResponse = response as? HTTPURLResponse,
       !(200...299).contains(httpResponse.statusCode) {
        throw NSError(
            domain: "OpenStreetMapSpeedLimits",
            code: httpResponse.statusCode,
            userInfo: [NSLocalizedDescriptionKey: "Overpass returned HTTP \(httpResponse.statusCode)."]
        )
    }

    let decoded = try JSONDecoder().decode(OverpassResponse.self, from: data)
    return decoded.elements.compactMap { element in
        guard let tags = element.tags,
              let speedLimit = speedLimitMetersPerSecond(from: tags),
              let geometry = element.geometry?.map({ CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon) }),
              geometry.count > 1 else {
            return nil
        }

        return OpenStreetMapWay(
            geometry: geometry,
            speedLimitMetersPerSecond: speedLimit
        )
    }
}

private func nearestSpeedLimit(
    forSegmentFrom start: CLLocationCoordinate2D,
    to end: CLLocationCoordinate2D,
    using ways: [OpenStreetMapWay]
) -> CLLocationSpeed? {
    let midpoint = MKMapPoint(midpointCoordinate(from: start, to: end))
    var bestMatch: (speed: CLLocationSpeed, distance: CLLocationDistance)?

    for way in ways {
        for (wayStart, wayEnd) in zip(way.geometry, way.geometry.dropFirst()) {
            let candidateDistance = distanceFromPoint(
                midpoint,
                toSegmentFrom: MKMapPoint(wayStart),
                to: MKMapPoint(wayEnd)
            )

            if bestMatch == nil || candidateDistance < bestMatch!.distance {
                bestMatch = (way.speedLimitMetersPerSecond, candidateDistance)
            }
        }
    }

    guard let bestMatch,
          bestMatch.distance <= OpenStreetMapSpeedLimitService.nearestWayThreshold else {
        return nil
    }

    return bestMatch.speed
}

private func buildPlaybackSamples(
    from displayCoordinates: [CLLocationCoordinate2D],
    speedWays _: [OpenStreetMapWay],
    fallbackSpeedMetersPerSecond _: CLLocationSpeed
) -> [RoutePlaybackSample] {
    guard let firstCoordinate = displayCoordinates.first else { return [] }

    var samples = [RoutePlaybackSample(coordinate: firstCoordinate, delayFromPrevious: 0)]

    for (start, end) in zip(displayCoordinates, displayCoordinates.dropFirst()) {
        let segmentDistance = CLLocation(latitude: start.latitude, longitude: start.longitude)
            .distance(from: CLLocation(latitude: end.latitude, longitude: end.longitude))
        guard segmentDistance > 0 else { continue }

        let speed = RouteSimulationDefaults.fixedSpeedMetersPerSecond
        let segmentTravelTime = segmentDistance / speed
        let segmentStepCount = max(1, Int(ceil(segmentTravelTime / RouteSimulationDefaults.playbackTickInterval)))
        let stepDelay = segmentTravelTime / Double(segmentStepCount)

        for index in 1...segmentStepCount {
            let coordinate = interpolateCoordinate(
                from: start,
                to: end,
                fraction: Double(index) / Double(segmentStepCount)
            )
            if samples.last.map({ CoordinateSnapshot($0.coordinate) }) != CoordinateSnapshot(coordinate) {
                samples.append(RoutePlaybackSample(coordinate: coordinate, delayFromPrevious: stepDelay))
            }
        }
    }

    return samples
}

private func prefetchRoutePlaybackSamples(
    displayCoordinates: [CLLocationCoordinate2D],
    fallbackSpeedMetersPerSecond: CLLocationSpeed
) async -> [RoutePlaybackSample] {
    buildPlaybackSamples(
        from: displayCoordinates,
        speedWays: [],
        fallbackSpeedMetersPerSecond: fallbackSpeedMetersPerSecond
    )
}

private enum CoordinateImportError: LocalizedError {
    case emptyFile
    case noCoordinates

    var errorDescription: String? {
        switch self {
        case .emptyFile:
            return "選取的檔案是空的。"
        case .noCoordinates:
            return "找不到有效座標。請使用含緯度、經度的 GPX、GeoJSON、JSON、CSV 或純文字。"
        }
    }
}

private enum CoordinateImportParser {
    static let supportedContentTypes: [UTType] = [
        .plainText,
        .commaSeparatedText,
        .json,
        .xml,
        UTType(filenameExtension: "gpx", conformingTo: .xml) ?? .xml,
        UTType(filenameExtension: "kml", conformingTo: .xml) ?? .xml,
        UTType(filenameExtension: "geojson", conformingTo: .json) ?? .json
    ]

    private enum CoordinateOrder {
        case latitudeLongitude
        case longitudeLatitude
    }

    static func parse(url: URL) throws -> [CLLocationCoordinate2D] {
        let accessing = url.startAccessingSecurityScopedResource()
        defer {
            if accessing {
                url.stopAccessingSecurityScopedResource()
            }
        }

        let data = try Data(contentsOf: url)
        guard !data.isEmpty else { throw CoordinateImportError.emptyFile }

        let fileExtension = url.pathExtension.lowercased()
        if fileExtension == "json" || fileExtension == "geojson" {
            if let coordinates = try? parseJSONCoordinates(from: data),
               !coordinates.isEmpty {
                return coordinates
            }
        }

        if fileExtension == "gpx" || fileExtension == "kml" || fileExtension == "xml" {
            let coordinates = parseXMLCoordinates(from: data)
            if !coordinates.isEmpty {
                return coordinates
            }
        }

        if let text = decodedText(from: data) {
            let coordinates = parseInline(text)
            if !coordinates.isEmpty {
                return coordinates
            }
        }

        if let coordinates = try? parseJSONCoordinates(from: data),
           !coordinates.isEmpty {
            return coordinates
        }

        let coordinates = parseXMLCoordinates(from: data)
        if !coordinates.isEmpty {
            return coordinates
        }

        throw CoordinateImportError.noCoordinates
    }

    static func parseInline(_ text: String) -> [CLLocationCoordinate2D] {
        sanitized(parseTextCoordinates(from: text))
    }

    private static func decodedText(from data: Data) -> String? {
        String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .utf16)
            ?? String(data: data, encoding: .ascii)
    }

    private static func sanitized(_ coordinates: [CLLocationCoordinate2D]) -> [CLLocationCoordinate2D] {
        var result: [CLLocationCoordinate2D] = []
        for coordinate in coordinates where CLLocationCoordinate2DIsValid(coordinate) {
            if result.last.map(CoordinateSnapshot.init) == CoordinateSnapshot(coordinate) {
                continue
            }
            result.append(coordinate)
        }
        return result
    }

    private static func coordinate(
        first: Double,
        second: Double,
        order: CoordinateOrder
    ) -> CLLocationCoordinate2D? {
        let preferred: CLLocationCoordinate2D
        let fallback: CLLocationCoordinate2D

        switch order {
        case .latitudeLongitude:
            preferred = CLLocationCoordinate2D(latitude: first, longitude: second)
            fallback = CLLocationCoordinate2D(latitude: second, longitude: first)
        case .longitudeLatitude:
            preferred = CLLocationCoordinate2D(latitude: second, longitude: first)
            fallback = CLLocationCoordinate2D(latitude: first, longitude: second)
        }

        if CLLocationCoordinate2DIsValid(preferred) {
            return preferred
        }
        if CLLocationCoordinate2DIsValid(fallback) {
            return fallback
        }
        return nil
    }

    private static func parseJSONCoordinates(from data: Data) throws -> [CLLocationCoordinate2D] {
        let object = try JSONSerialization.jsonObject(with: data)
        return sanitized(coordinates(fromJSONObject: object, order: .latitudeLongitude))
    }

    private static func coordinates(
        fromJSONObject object: Any,
        order: CoordinateOrder
    ) -> [CLLocationCoordinate2D] {
        if let dictionary = object as? [String: Any] {
            if let latitude = numberValue(forAnyKey: ["latitude", "lat"], in: dictionary),
               let longitude = numberValue(forAnyKey: ["longitude", "lon", "lng"], in: dictionary),
               let coordinate = coordinate(first: latitude, second: longitude, order: .latitudeLongitude) {
                return [coordinate]
            }

            if let geometry = dictionary["geometry"] {
                return coordinates(fromJSONObject: geometry, order: order)
            }

            if let type = dictionary["type"] as? String {
                let loweredType = type.lowercased()
                if loweredType == "featurecollection",
                   let features = dictionary["features"] as? [Any] {
                    return features.flatMap { coordinates(fromJSONObject: $0, order: .longitudeLatitude) }
                }
                if loweredType == "geometrycollection",
                   let geometries = dictionary["geometries"] as? [Any] {
                    return geometries.flatMap { coordinates(fromJSONObject: $0, order: .longitudeLatitude) }
                }
                if let coordinateObject = dictionary["coordinates"] {
                    return coordinates(fromJSONObject: coordinateObject, order: .longitudeLatitude)
                }
            }

            return dictionary.values.flatMap { coordinates(fromJSONObject: $0, order: order) }
        }

        if let array = object as? [Any] {
            if array.count >= 2,
               let first = numericValue(array[0]),
               let second = numericValue(array[1]),
               let coordinate = coordinate(first: first, second: second, order: order) {
                return [coordinate]
            }

            return array.flatMap { coordinates(fromJSONObject: $0, order: order) }
        }

        return []
    }

    private static func numericValue(_ value: Any) -> Double? {
        if let number = value as? NSNumber {
            return number.doubleValue
        }
        if let string = value as? String {
            return Double(string.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return nil
    }

    private static func numberValue(forAnyKey keys: [String], in dictionary: [String: Any]) -> Double? {
        let keyedValues = Dictionary(uniqueKeysWithValues: dictionary.map { ($0.key.lowercased(), $0.value) })
        for key in keys {
            if let value = keyedValues[key],
               let number = numericValue(value) {
                return number
            }
        }
        return nil
    }

    private static func parseXMLCoordinates(from data: Data) -> [CLLocationCoordinate2D] {
        let collector = XMLCoordinateCollector()
        let parser = XMLParser(data: data)
        parser.delegate = collector
        guard parser.parse() else { return [] }
        return sanitized(collector.coordinates)
    }

    private final class XMLCoordinateCollector: NSObject, XMLParserDelegate {
        var coordinates: [CLLocationCoordinate2D] = []
        private var isCollectingKMLCoordinates = false
        private var kmlCoordinateBuffer = ""

        func parser(
            _ parser: XMLParser,
            didStartElement elementName: String,
            namespaceURI: String?,
            qualifiedName qName: String?,
            attributes attributeDict: [String: String] = [:]
        ) {
            let name = elementName.lowercased()
            if ["wpt", "trkpt", "rtept"].contains(name),
               let latitude = Double(attributeDict["lat"] ?? ""),
               let longitude = Double(attributeDict["lon"] ?? ""),
               let coordinate = CoordinateImportParser.coordinate(
                    first: latitude,
                    second: longitude,
                    order: .latitudeLongitude
               ) {
                coordinates.append(coordinate)
            } else if name == "coordinates" {
                isCollectingKMLCoordinates = true
                kmlCoordinateBuffer = ""
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            if isCollectingKMLCoordinates {
                kmlCoordinateBuffer += string
            }
        }

        func parser(
            _ parser: XMLParser,
            didEndElement elementName: String,
            namespaceURI: String?,
            qualifiedName qName: String?
        ) {
            guard elementName.lowercased() == "coordinates" else { return }
            coordinates.append(contentsOf: CoordinateImportParser.parseKMLCoordinateText(kmlCoordinateBuffer))
            isCollectingKMLCoordinates = false
            kmlCoordinateBuffer = ""
        }
    }

    private static func parseKMLCoordinateText(_ text: String) -> [CLLocationCoordinate2D] {
        text
            .split(whereSeparator: { $0.isWhitespace })
            .compactMap { token -> CLLocationCoordinate2D? in
                let values = token
                    .split(separator: ",")
                    .compactMap { Double($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
                guard values.count >= 2 else { return nil }
                return coordinate(first: values[0], second: values[1], order: .longitudeLatitude)
            }
    }

    private static func parseTextCoordinates(from text: String) -> [CLLocationCoordinate2D] {
        var coordinates: [CLLocationCoordinate2D] = []
        var headerIndices: (latitude: Int, longitude: Int)?

        for line in text.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }

            let fields = splitFields(trimmed)
            if headerIndices == nil,
               let detectedHeader = detectHeader(in: fields) {
                headerIndices = detectedHeader
                continue
            }

            if let headerIndices,
               fields.indices.contains(headerIndices.latitude),
               fields.indices.contains(headerIndices.longitude),
               let latitude = numbers(in: fields[headerIndices.latitude]).first,
               let longitude = numbers(in: fields[headerIndices.longitude]).first,
               let coordinate = coordinate(first: latitude, second: longitude, order: .latitudeLongitude) {
                coordinates.append(coordinate)
                continue
            }

            let values = numbers(in: trimmed)
            if values.count >= 2,
               let coordinate = coordinate(first: values[0], second: values[1], order: .latitudeLongitude) {
                coordinates.append(coordinate)
            }
        }

        return coordinates
    }

    private static func splitFields(_ line: String) -> [String] {
        line
            .split { character in
                character == "," ||
                character == ";" ||
                character == "\t"
            }
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
    }

    private static func detectHeader(in fields: [String]) -> (latitude: Int, longitude: Int)? {
        let lowered = fields.map { $0.lowercased() }
        guard let latitude = lowered.firstIndex(where: { $0 == "lat" || $0 == "latitude" }),
              let longitude = lowered.firstIndex(where: { $0 == "lon" || $0 == "lng" || $0 == "long" || $0 == "longitude" }) else {
            return nil
        }
        return (latitude, longitude)
    }

    private static func numbers(in text: String) -> [Double] {
        let pattern = #"[-+]?(?:\d+(?:\.\d*)?|\.\d+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.matches(in: text, range: range).compactMap { match in
            guard let matchRange = Range(match.range, in: text) else { return nil }
            return Double(text[matchRange])
        }
    }
}

// MARK: - Bookmark Model

struct LocationBookmark: Identifiable, Codable {
    var id: UUID = UUID()
    var name: String
    var latitude: Double
    var longitude: Double

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}

// MARK: - Search Completer

@MainActor
final class LocationSearchCompleter: NSObject, ObservableObject, MKLocalSearchCompleterDelegate {
    @Published var results: [MKLocalSearchCompletion] = []
    private let completer = MKLocalSearchCompleter()

    override init() {
        super.init()
        completer.delegate = self
        completer.resultTypes = [.address, .pointOfInterest]
    }

    func update(query: String) {
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            results = []
            completer.queryFragment = ""
            return
        }
        completer.queryFragment = query
    }

    nonisolated func completerDidUpdateResults(_ completer: MKLocalSearchCompleter) {
        let results = completer.results
        Task { @MainActor in self.results = results }
    }

    nonisolated func completer(_ completer: MKLocalSearchCompleter, didFailWithError error: Error) {
        Task { @MainActor in self.results = [] }
    }
}

struct LocationSimulationView: View {
    @ObservedObject private var simulationSession = LocationSimulationSession.shared
    @ObservedObject private var readiness = ReadinessMonitor.shared
    @State private var coordinate: CLLocationCoordinate2D?
    @State private var position: MapCameraPosition = .userLocation(fallback: .automatic)

    @State private var backgroundTaskID: UIBackgroundTaskIdentifier = .invalid
    @State private var routeLoadTask: Task<Void, Never>?
    @State private var routeSpeedPrefetchTask: Task<Void, Never>?
    @State private var routePlaybackTask: Task<Void, Never>?
    @State private var isBusy = false
    @State private var isLoadingRoute = false
    @State private var isPrefetchingRouteSpeeds = false
    @State private var showAlert = false
    @State private var alertTitle = ""
    @State private var alertMessage = ""

    @State private var searchText = ""
    @StateObject private var searchCompleter = LocationSearchCompleter()
    @StateObject private var directionsPlanner = DirectionsPlannerModel()
    @State private var isPlanningRoute = false
    @State private var routeModePreviews: [RouteNavigationMode: RouteModePreview] = [:]
    @State private var routeStartSelection: RouteSearchSelection?
    @State private var routeEndSelection: RouteSearchSelection?
    @State private var routePlan: RouteSimulationPlan?
    @State private var routePolyline: MKPolyline?
    @State private var routePlaybackSamples: [RoutePlaybackSample] = []
    @State private var routePlaybackCoordinate: CLLocationCoordinate2D?
    @State private var routePlaybackIndex = 0
    @State private var activeRouteID: UUID?
    @State private var isRoutePaused = false
    @State private var shouldAutoStartRoute = false
    @State private var simulatedCoordinate: CLLocationCoordinate2D?
    @State private var routeRequestID = UUID()
    @State private var isNavigationCameraFollowing = true
    @State private var navigationCamera = NavigationCameraSession()
    @AppStorage(UserDefaults.Keys.routeSpeedAutomobileKilometersPerHour) private var automobileSpeed = RouteSimulationSpeed.defaultKilometersPerHour
    @AppStorage(UserDefaults.Keys.routeSpeedCyclingKilometersPerHour) private var cyclingSpeed = RouteSimulationSpeed.defaultKilometersPerHour
    @AppStorage(UserDefaults.Keys.routeSpeedWalkingKilometersPerHour) private var walkingSpeed = RouteSimulationSpeed.defaultKilometersPerHour
    @AppStorage(UserDefaults.Keys.routeSpeedAirplaneKilometersPerHour) private var airplaneSpeed = RouteSimulationSpeed.defaultKilometersPerHour
    @AppStorage(UserDefaults.Keys.routeNavigationMode) private var routeNavigationMode = RouteNavigationMode.defaultMode.rawValue

    // Bookmarks
    @State private var bookmarks: [LocationBookmark] = []
    @State private var showBookmarks = false
    @State private var locationManager = CLLocationManager()

    private var pairingFilePath: String {
        PairingFileStore.prepareURL().path
    }

    private var pairingExists: Bool {
        FileManager.default.fileExists(atPath: pairingFilePath)
    }

    private var deviceIP: String {
        DeviceConnectionContext.targetIPAddress
    }

    private var routeStartCoordinate: CLLocationCoordinate2D? {
        routeStartSelection?.coordinate
    }

    private var routeEndCoordinate: CLLocationCoordinate2D? {
        routeEndSelection?.coordinate
    }

    private var isRouteWalking: Bool {
        routePlaybackTask != nil
    }

    private var isRouteRunning: Bool {
        isRouteWalking || isRoutePaused || simulationSession.routeCoordinates != nil
    }

    private var hasRouteContext: Bool {
        routeStartSelection != nil ||
        routeEndSelection != nil ||
        routePlan != nil ||
        isLoadingRoute ||
        isPrefetchingRouteSpeeds ||
        routePlaybackCoordinate != nil ||
        simulationSession.routeCoordinates != nil
    }

    private var isNavigatingRoute: Bool {
        isRouteWalking || isRoutePaused || (simulationSession.routeCoordinates != nil && routePlan != nil)
    }

    private var remainingRouteDistance: CLLocationDistance {
        guard routePlaybackSamples.count > 1 else {
            return routePlan?.distance ?? 0
        }
        let startIndex = min(max(routePlaybackIndex, 0), routePlaybackSamples.count - 1)
        var distance: CLLocationDistance = 0
        var previous = routePlaybackSamples[startIndex].coordinate
        for sample in routePlaybackSamples[(startIndex + 1)...] {
            distance += CLLocation(latitude: previous.latitude, longitude: previous.longitude)
                .distance(from: CLLocation(latitude: sample.coordinate.latitude, longitude: sample.coordinate.longitude))
            previous = sample.coordinate
        }
        return distance
    }

    private var remainingRouteTime: TimeInterval {
        guard routePlaybackSamples.indices.contains(routePlaybackIndex) else {
            return routePlan?.expectedTravelTime ?? 0
        }
        return routePlaybackSamples[(routePlaybackIndex + 1)...].reduce(0) { $0 + $1.delayFromPrevious }
    }

    private var remainingDurationText: String {
        let seconds = remainingRouteTime
        if remainingRouteDistance < 15 || seconds < 20 {
            return "已抵達"
        }
        if seconds >= 3600 {
            let hours = Int(seconds) / 3600
            let minutes = Int(seconds.truncatingRemainder(dividingBy: 3600) / 60)
            return minutes == 0 ? "\(hours)小時" : "\(hours)小時 \(minutes)分鐘"
        }
        let minutes = max(1, Int((seconds / 60).rounded()))
        return "\(minutes)分鐘"
    }

    private var remainingDistanceText: String {
        let meters = remainingRouteDistance
        if meters < 1000 {
            return "\(max(0, Int(meters.rounded()))) 公尺"
        }
        return String(format: "%.1f 公里", meters / 1000)
    }

    private var navigationLiveActivityState: NavigationActivityAttributes.ContentState {
        NavigationActivityAttributes.ContentState(
            destinationName: navigationDestinationName,
            remainingTimeText: remainingDurationText,
            remainingDistanceText: remainingDistanceText,
            etaText: arrivalTimeText,
            modeSymbolName: selectedPlanningMode.systemImage,
            isPaused: isRoutePaused
        )
    }

    private func syncNavigationLiveActivity(force: Bool = false) {
        guard isNavigatingRoute else { return }
        NavigationLiveActivityController.shared.update(state: navigationLiveActivityState, force: force)
    }

    private var arrivalTimeText: String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_Hant_TW")
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: Date().addingTimeInterval(max(0, remainingRouteTime)))
    }

    private var displayedRouteCoordinate: CLLocationCoordinate2D? {
        simulationSession.routeCoordinates == nil ? routePlaybackCoordinate : simulationSession.coordinate
    }

    private var selectedPlanningMode: RouteNavigationMode {
        RouteNavigationMode(rawValue: routeNavigationMode) ?? .defaultMode
    }

    private var selectedPlanningSpeed: Double {
        RouteSimulationSpeed.kilometersPerHour(for: selectedPlanningMode)
    }

    private func refreshRouteIfSpeedChanged() {
        if hasRouteContext, !isRouteRunning {
            refreshRoute()
        }
    }

    private var selectedPlanningPreview: RouteModePreview? {
        routeModePreviews[selectedPlanningMode]
    }

    private var canStartPlannedRoute: Bool {
        pairingExists &&
            !isBusy &&
            !isLoadingRoute &&
            !isPrefetchingRouteSpeeds &&
            directionsPlanner.startSelection != nil &&
            directionsPlanner.endSelection != nil &&
            routePlan != nil &&
            !routePlaybackSamples.isEmpty
    }

    private var searchResultsListBase: some View {
        List(searchCompleter.results.prefix(5), id: \.self) { result in
            Button {
                selectSearchResult(result)
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(result.title)
                        .font(.subheadline)
                    if !result.subtitle.isEmpty {
                        Text(result.subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .listStyle(.plain)
        .frame(maxHeight: 350)
        .scrollDisabled(true)
        .padding(.horizontal, 12)
        .padding(.top, 8)
    }

    @ViewBuilder
    private var searchResultsList: some View {
        if #available(iOS 26, *) {
            searchResultsListBase
                .glassEffect(in: .rect(cornerRadius: 12))
        } else {
            searchResultsListBase
        }
    }

    private var airplaneToggleBanner: some View {
        Label(readiness.airplanePromptMessage, systemImage: "airplane")
            .font(.footnote.weight(.semibold))
            .foregroundStyle(.primary)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.orange.opacity(0.18), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var mapSearchBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.body.weight(.semibold))
                .foregroundStyle(.secondary)
            TextField("搜尋地點…", text: $searchText)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .submitLabel(.go)
                .onChange(of: searchText) { _, newValue in
                    searchCompleter.update(query: newValue)
                }
                .onSubmit {
                    applyCoordinatesFromSearchText()
                }
            if !searchText.isEmpty {
                Button {
                    searchText = ""
                    searchCompleter.results = []
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("清除搜尋")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
        .background(Color(.systemBackground), in: Capsule())
        .shadow(color: .black.opacity(0.14), radius: 12, y: 4)
    }

    private var routeSearchButton: some View {
        Button {
            beginPlanningRoute()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "point.topleft.down.curvedto.point.bottomright.up")
                    .font(.body.weight(.semibold))
                Text("移動")
                    .font(.body.weight(.semibold))
            }
            .foregroundStyle(.primary)
            .padding(.horizontal, 14)
            .frame(height: 48)
            .background(Color(.systemBackground), in: Capsule())
            .shadow(color: .black.opacity(0.14), radius: 12, y: 4)
        }
        .buttonStyle(.plain)
        .disabled(isBusy || isRouteRunning)
        .accessibilityLabel("移動")
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            RouteMapCanvas(
                position: $position,
                hasRouteContext: hasRouteContext,
                isNavigatingRoute: isNavigatingRoute,
                routeCoordinates: routePlan?.displayCoordinates,
                routeStart: routeStartCoordinate,
                routeEnd: routeEndCoordinate,
                pinCoordinate: hasRouteContext ? nil : coordinate,
                displayedRouteCoordinate: isNavigatingRoute ? nil : displayedRouteCoordinate,
                onTap: handleMapTap,
                onUnlock: unlockNavigationCamera
            )
            .equatable()
                .ignoresSafeArea()
            .overlay {
                NavigationCameraBridge(
                    session: navigationCamera,
                    isNavigating: isNavigatingRoute
                )
                .allowsHitTesting(false)
                }

            VStack(spacing: 0) {
                if isNavigatingRoute {
                    navigationDestinationBanner
                        .padding(.horizontal, 12)
                        .padding(.top, 8)
                        .padding(.bottom, 8)
                } else if isPlanningRoute {
                    DirectionsHeaderCard(planner: directionsPlanner) {
                        cancelPlanningRoute()
                    }
                    .padding(.horizontal, 12)
                    .padding(.top, 8)
                } else {
                    HStack(spacing: 10) {
                        mapSearchBar
                        routeSearchButton
                    }
                    .padding(.horizontal, 12)
                    .padding(.top, 8)
                    if readiness.shouldPromptAirplaneToggle {
                        airplaneToggleBanner
                            .padding(.horizontal, 12)
                            .padding(.top, 8)
                    }
                if !searchCompleter.results.isEmpty {
                    searchResultsList
                    }
                }

                Spacer()

                HStack(alignment: .bottom, spacing: 12) {
                    if isNavigatingRoute {
                        if showsReturnToNavigation {
                            returnToNavigationButton
                        } else {
                            navigationSpeedometer
                        }
                        Spacer(minLength: 0)
                    } else if isPlanningRoute {
                        Spacer(minLength: 0)
                VStack(spacing: 12) {
                            recenterOnUserLocationButton
                            AppleMapsCompass()
                                .frame(width: 40, height: 40)
                        }
                    } else if hasRouteContext {
                        routeControls
                        Spacer(minLength: 8)
                        VStack(spacing: 12) {
                            recenterOnUserLocationButton
                            AppleMapsCompass()
                                .frame(width: 40, height: 40)
                        }
                    } else if !pairingExists {
                        pinControls
                        Spacer(minLength: 8)
                        VStack(spacing: 12) {
                            recenterOnUserLocationButton
                            AppleMapsCompass()
                                .frame(width: 40, height: 40)
                        }
                    } else {
                        Spacer(minLength: 0)
                        VStack(spacing: 12) {
                            recenterOnUserLocationButton
                            AppleMapsCompass()
                                .frame(width: 40, height: 40)
                        }
                    }
                }
                .padding(.horizontal, 16)

                if isNavigatingRoute {
                    navigationBanner
                        .padding(.horizontal, 16)
                        .padding(.top, 8)
                } else if isPlanningRoute {
                    DirectionsModeBar(
                        selectedMode: Binding(
                            get: { RouteNavigationMode(rawValue: routeNavigationMode) ?? .defaultMode },
                            set: { routeNavigationMode = $0.rawValue }
                        ),
                        modePreviews: routeModePreviews,
                        selectedPreview: selectedPlanningPreview,
                        speedKilometersPerHour: selectedPlanningSpeed,
                        isLoading: isLoadingRoute,
                        canStart: canStartPlannedRoute
                    ) {
                        startPlannedRoute()
                    }
                    .padding(.horizontal, 12)
                    .padding(.top, 10)
                }
            }
            .padding(.bottom, 24)
            .safeAreaPadding(.top)
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .navigationBar)
        .alert(alertTitle, isPresented: $showAlert) {
            Button("確定", role: .cancel) { }
        } message: {
            Text(alertMessage)
        }
        .onReceive(NotificationCenter.default.publisher(for: .restoreRealLocation)) { _ in
            resetSimulationUI()
        }
        .onReceive(NotificationCenter.default.publisher(for: .simulateSavedCoordinate)) { notification in
            applySavedCoordinate(from: notification)
        }
        .sheet(isPresented: $showBookmarks) {
            BookmarksView(
                bookmarks: $bookmarks,
                currentCoordinate: coordinate ?? displayedRouteCoordinate ?? simulatedCoordinate
            ) { bookmark in
                applySelection(bookmark.coordinate, focusCamera: true)
                showBookmarks = false
            } onDelete: { offsets in
                bookmarks.remove(atOffsets: offsets)
                saveBookmarks()
            } onAdd: { name, coord in
                addBookmark(named: name, at: coord)
            }
        }
        .onChange(of: directionsPlanner.startSelection) { _, _ in
            syncPlannerSelectionsToRoute()
        }
        .onChange(of: directionsPlanner.endSelection) { _, _ in
            syncPlannerSelectionsToRoute()
        }
        .onChange(of: automobileSpeed) { _, _ in refreshRouteIfSpeedChanged() }
        .onChange(of: cyclingSpeed) { _, _ in refreshRouteIfSpeedChanged() }
        .onChange(of: walkingSpeed) { _, _ in refreshRouteIfSpeedChanged() }
        .onChange(of: airplaneSpeed) { _, _ in refreshRouteIfSpeedChanged() }
        .onChange(of: routeNavigationMode) { _, newValue in
            guard !isRouteRunning else { return }
            let mode = RouteNavigationMode(rawValue: newValue) ?? .defaultMode
            if let preview = routeModePreviews[mode] {
                adoptRoutePreview(preview)
            } else if hasRouteContext || isPlanningRoute {
                refreshRoute()
            }
        }
        .onAppear {
            loadBookmarks()
            prepareCurrentLocationIfNeeded()
            restoreMapAfterReturning()
        }
        .onDisappear {
            routeLoadTask?.cancel()
            routeLoadTask = nil
            routeSpeedPrefetchTask?.cancel()
            routeSpeedPrefetchTask = nil
            navigationCamera.detach()
            if !isNavigatingRoute {
                navigationCamera.stop()
                endBackgroundTask()
            }
        }
        .onChange(of: isNavigationCameraFollowing) { _, isFollowing in
            navigationCamera.isFollowing = isFollowing
        }
    }

    private var showsReturnToNavigation: Bool {
        isNavigatingRoute && !isNavigationCameraFollowing
    }

    private var recenterOnUserLocationButton: some View {
        Button(action: recenterOnUserLocation) {
            Image(systemName: "location.fill")
                .font(.body.weight(.semibold))
                .foregroundStyle(.blue)
                .frame(width: 44, height: 44)
                .background(.ultraThinMaterial, in: Circle())
                .shadow(color: .black.opacity(0.16), radius: 4, y: 2)
        }
        .accessibilityLabel("回到目前位置")
    }

    private var returnToNavigationButton: some View {
        Button(action: recenterOnUserLocation) {
            Label("返回目前位置", systemImage: "location.north.fill")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(.ultraThinMaterial, in: Capsule())
                .shadow(color: .black.opacity(0.16), radius: 4, y: 2)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("返回目前位置")
    }

    private var currentLocationSelection: RouteSearchSelection? {
        let coord =
            displayedRouteCoordinate
            ?? simulatedCoordinate
            ?? simulationSession.coordinate
            ?? coordinate
            ?? locationManager.location?.coordinate
        guard let coord, CLLocationCoordinate2DIsValid(coord) else { return nil }
        return RouteSearchSelection(title: "你的位置", coordinate: coord)
    }

    private func prepareCurrentLocationIfNeeded() {
        switch locationManager.authorizationStatus {
        case .notDetermined:
            locationManager.requestWhenInUseAuthorization()
        case .authorizedAlways, .authorizedWhenInUse:
            locationManager.startUpdatingLocation()
        default:
            break
        }
    }

    private func beginPlanningRoute() {
        prepareCurrentLocationIfNeeded()
        directionsPlanner.begin(
            start: currentLocationSelection ?? routeStartSelection,
            end: routeEndSelection
        )
        routeStartSelection = directionsPlanner.startSelection
        routeEndSelection = directionsPlanner.endSelection
        isPlanningRoute = true
        if let start = directionsPlanner.startSelection, let end = directionsPlanner.endSelection {
            previewRoute(start: start, end: end)
        }
    }

    private func cancelPlanningRoute() {
        isPlanningRoute = false
        directionsPlanner.reset()
        if !isRouteRunning {
            resetRouteSelection()
        }
    }

    private func startPlannedRoute() {
        guard let start = directionsPlanner.startSelection,
              let end = directionsPlanner.endSelection else {
            return
        }
        isPlanningRoute = false
        startWalkingRoute(start: start, end: end)
    }

    private func syncPlannerSelectionsToRoute() {
        guard isPlanningRoute else { return }
        routeStartSelection = directionsPlanner.startSelection
        routeEndSelection = directionsPlanner.endSelection
        if let start = directionsPlanner.startSelection, let end = directionsPlanner.endSelection {
            previewRoute(start: start, end: end)
        } else if !isRouteRunning {
            let start = routeStartSelection
            resetRouteSelection()
            routeStartSelection = start
        }
    }

    private func handleMapTap(_ coordinate: CLLocationCoordinate2D) {
        guard !isNavigatingRoute else { return }
        if isPlanningRoute {
            pickPlanningCoordinate(coordinate)
        } else {
            applySelection(coordinate)
        }
    }

    private func pickPlanningCoordinate(_ coordinate: CLLocationCoordinate2D) {
        guard CLLocationCoordinate2DIsValid(coordinate) else { return }
        let field = directionsPlanner.focusedField ?? (directionsPlanner.endSelection == nil ? .end : .start)
        directionsPlanner.applyPicked(
            RouteSearchSelection(title: field == .start ? "出發點" : "目的地", coordinate: coordinate),
            field: field
        )
        let location = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        CLGeocoder().reverseGeocodeLocation(location) { placemarks, _ in
            let name = (placemarks?.first?.name ?? placemarks?.first?.thoroughfare)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard let name, !name.isEmpty else { return }
            DispatchQueue.main.async {
                guard isPlanningRoute else { return }
                directionsPlanner.applyPicked(
                    RouteSearchSelection(title: name, coordinate: coordinate),
                    field: field
                )
            }
        }
    }

    private func recenterOnUserLocation() {
        switch locationManager.authorizationStatus {
        case .notDetermined:
            locationManager.requestWhenInUseAuthorization()
        case .denied, .restricted:
            alertTitle = "無法取得位置"
            alertMessage = "請到「設定 → 隱私權與安全性 → 定位服務」允許此 App 使用定位。"
            showAlert = true
            return
        default:
            break
        }

        locationManager.startUpdatingLocation()
        if isNavigatingRoute {
            restoreNavigationCamera(animated: true)
            return
        }
        position = .userLocation(followsHeading: false, fallback: .automatic)
    }

    private func restoreMapAfterReturning() {
        if let routeCoordinates = simulationSession.routeCoordinates, routeCoordinates.count > 1 {
                coordinate = nil
                routePolyline = makeRoutePolyline(for: routeCoordinates)
            if routeStartSelection == nil {
                routeStartSelection = routeCoordinates.first.map {
                    RouteSearchSelection(title: "路線起點", coordinate: $0)
                }
            }
            if routeEndSelection == nil {
                routeEndSelection = routeCoordinates.last.map {
                    RouteSearchSelection(title: "路線終點", coordinate: $0)
                }
            }
            if routePlan == nil {
                setRoutePlan(
                    RouteSimulationPlan(
                        displayCoordinates: routeCoordinates,
                        distance: 0,
                        expectedTravelTime: 0
                    )
                )
            }
            restoreNavigationCamera(animated: false)
            return
        }
        if let activeCoordinate = simulationSession.coordinate {
                coordinate = activeCoordinate
                simulatedCoordinate = activeCoordinate
            }
        }

    private func restoreNavigationCamera(animated: Bool) {
        ensureNavigationCameraSamples()
        isNavigationCameraFollowing = true
        navigationCamera.isFollowing = true
        if isRouteWalking, !navigationCamera.isWalking {
            navigationCamera.start(fromElapsed: currentNavigationElapsed())
        } else if isRoutePaused, navigationCamera.isWalking {
            navigationCamera.pause()
        }
        navigationCamera.snapAndApply()
        let coordinate =
            navigationCamera.currentCoordinate
            ?? routePlaybackCoordinate
            ?? displayedRouteCoordinate
            ?? simulationSession.coordinate
        if let coordinate {
            syncSwiftUINavigationCamera(
                at: coordinate,
                heading: navigationCamera.cameraHeading,
                animated: animated
            )
        }
    }

    private func ensureNavigationCameraSamples() {
        if navigationCamera.samples.isEmpty {
            if routePlaybackSamples.isEmpty, let routeCoordinates = routePlan?.displayCoordinates ?? simulationSession.routeCoordinates {
                routePlaybackSamples = buildPlaybackSamples(
                    from: routeCoordinates,
                    speedWays: [],
                    fallbackSpeedMetersPerSecond: RouteSimulationDefaults.fixedSpeedMetersPerSecond
                )
            }
            guard !routePlaybackSamples.isEmpty else { return }
            navigationCamera.configure(samples: routePlaybackSamples)
            if isRouteWalking {
                navigationCamera.start(fromElapsed: currentNavigationElapsed())
            } else {
                navigationCamera.start(fromElapsed: currentNavigationElapsed())
                navigationCamera.pause()
            }
        }
    }

    private func currentNavigationElapsed() -> TimeInterval {
        if !navigationCamera.samples.isEmpty {
            return min(navigationCamera.elapsed, navigationCamera.totalDuration)
        }
        guard routePlaybackSamples.indices.contains(routePlaybackIndex) else { return 0 }
        return routePlaybackSamples.prefix(routePlaybackIndex + 1).dropFirst().reduce(0) { $0 + $1.delayFromPrevious }
    }

    // MARK: - Bookmarks

    private func loadBookmarks() {
        guard let data = UserDefaults.standard.data(forKey: "locationBookmarks"),
              let decoded = try? JSONDecoder().decode([LocationBookmark].self, from: data) else { return }
        bookmarks = decoded
    }

    private func saveBookmarks() {
        if let data = try? JSONEncoder().encode(bookmarks) {
            UserDefaults.standard.set(data, forKey: "locationBookmarks")
        }
    }

    private func addBookmark(named name: String, at coord: CLLocationCoordinate2D) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let bookmark = LocationBookmark(
            name: trimmed.isEmpty ? String(format: "%.4f, %.4f", coord.latitude, coord.longitude) : trimmed,
            latitude: coord.latitude,
            longitude: coord.longitude
        )
        bookmarks.append(bookmark)
        saveBookmarks()
    }

    private func setRoutePlan(_ plan: RouteSimulationPlan?) {
        routePlan = plan
        routePolyline = plan.flatMap { makeRoutePolyline(for: $0.displayCoordinates) }
    }

    private func focusCamera(on polyline: MKPolyline) {
        var rect = polyline.boundingMapRect
        let padX = max(rect.size.width * 0.22, 80)
        let padY = max(rect.size.height * 0.22, 80)
        rect = rect.insetBy(dx: -padX, dy: -padY)
        position = .rect(rect)
    }

    private func interpolatedPlaybackCoordinate() -> CLLocationCoordinate2D? {
        navigationCamera.currentCoordinate ?? routePlaybackCoordinate
    }

    private func unlockNavigationCamera() {
        guard isNavigatingRoute, isNavigationCameraFollowing else { return }
        isNavigationCameraFollowing = false
        navigationCamera.isFollowing = false
    }

    private func syncSwiftUINavigationCamera(
        at coordinate: CLLocationCoordinate2D,
        heading: CLLocationDirection,
        animated: Bool
    ) {
        guard isNavigationCameraFollowing else { return }
        let center = coordinateByMoving(
            coordinate,
            distance: RouteSimulationDefaults.navigationCenterOffset,
            heading: heading
        )
        let camera = MapCamera(
            centerCoordinate: center,
            distance: RouteSimulationDefaults.navigationCameraDistance,
            heading: heading,
            pitch: RouteSimulationDefaults.navigationCameraPitch
        )
        if animated {
            withAnimation(.easeInOut(duration: 0.35)) {
                position = .camera(camera)
            }
        } else {
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                position = .camera(camera)
            }
        }
    }

    private func previewRoute(start: RouteSearchSelection, end: RouteSearchSelection) {
        let sameEndpoints =
            routeStartSelection.map { CoordinateSnapshot($0.coordinate) } == CoordinateSnapshot(start.coordinate) &&
            routeEndSelection.map { CoordinateSnapshot($0.coordinate) } == CoordinateSnapshot(end.coordinate)
        routeStartSelection = start
        routeEndSelection = end
        coordinate = nil
        if sameEndpoints, routePlan != nil || isLoadingRoute {
            return
        }
        refreshRoute(autoStart: false)
    }

    private func startWalkingRoute(start: RouteSearchSelection, end: RouteSearchSelection) {
        isPlanningRoute = false
        if isRouteRunning || hasRouteContext {
            cancelRoutePlayback(resetMarker: true)
            stopResendLoop()
            resetRouteSelection()
        }
        routeStartSelection = start
        routeEndSelection = end
        coordinate = nil
        refreshRoute(autoStart: true)
    }

    private func makeRoutePolyline(for coordinates: [CLLocationCoordinate2D]) -> MKPolyline? {
        guard coordinates.count > 1 else { return nil }
        return coordinates.withUnsafeBufferPointer { buffer in
            guard let baseAddress = buffer.baseAddress else { return nil }
            return MKPolyline(coordinates: baseAddress, count: buffer.count)
        }
    }

    // MARK: - Location

    private func selectSearchResult(_ result: MKLocalSearchCompletion) {
        searchText = ""
        searchCompleter.results = []

        let request = MKLocalSearch.Request(completion: result)
        MKLocalSearch(request: request).start { response, _ in
            guard let item = response?.mapItems.first else { return }
            let coordinate = item.placemark.coordinate
            DispatchQueue.main.async {
                applySelection(coordinate, focusCamera: true)
            }
        }
    }

    private func applyCoordinatesFromSearchText() {
        let importedCoordinates = CoordinateImportParser.parseInline(searchText)
        guard !importedCoordinates.isEmpty else { return }

        searchText = ""
        searchCompleter.results = []
        applyImportedCoordinates(importedCoordinates, sourceName: "匯入")
    }

    private func applyImportedCoordinates(
        _ importedCoordinates: [CLLocationCoordinate2D],
        sourceName: String
    ) {
        let coordinates = importedCoordinates.filter(CLLocationCoordinate2DIsValid)
        guard let firstCoordinate = coordinates.first else {
            showImportError(CoordinateImportError.noCoordinates)
            return
        }

        if coordinates.count == 1 {
            applySelection(firstCoordinate, focusCamera: true)
            return
        }

        if isRouteRunning || hasRouteContext {
            cancelRoutePlayback(resetMarker: true)
            stopResendLoop()
            resetRouteSelection()
        }

        routeLoadTask?.cancel()
        routeLoadTask = nil
        routeSpeedPrefetchTask?.cancel()
        routeSpeedPrefetchTask = nil
        routeRequestID = UUID()
        setRoutePlan(nil)
        routePlaybackSamples = []
        routePlaybackCoordinate = nil
        isLoadingRoute = false
        isPrefetchingRouteSpeeds = false
        coordinate = nil

        let displayCoordinates = sampledRouteCoordinates(
            from: coordinates,
            targetDistance: RouteSimulationDefaults.pathSamplingDistance
        )

        guard displayCoordinates.count > 1,
              let lastCoordinate = displayCoordinates.last else {
            applySelection(firstCoordinate, focusCamera: true)
            return
        }

        let distance = distanceAlong(displayCoordinates)
        let fallbackSpeed = RouteSimulationDefaults.fixedSpeedMetersPerSecond
        routeStartSelection = RouteSearchSelection(title: "\(sourceName) 起點", coordinate: firstCoordinate)
        routeEndSelection = RouteSearchSelection(title: "\(sourceName) 終點", coordinate: lastCoordinate)
        setRoutePlan(RouteSimulationPlan(
            displayCoordinates: displayCoordinates,
            distance: distance,
            expectedTravelTime: distance / fallbackSpeed
        ))

        if let routePolyline {
            position = .rect(routePolyline.boundingMapRect)
        }

        let requestID = UUID()
        routeRequestID = requestID
        isPrefetchingRouteSpeeds = true
        routeSpeedPrefetchTask = Task.detached(priority: .utility) {
            let playbackSamples = await prefetchRoutePlaybackSamples(
                displayCoordinates: displayCoordinates,
                fallbackSpeedMetersPerSecond: fallbackSpeed
            )
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard routeRequestID == requestID else { return }
                routePlaybackSamples = playbackSamples
                isPrefetchingRouteSpeeds = false
            }
        }
    }

    private func showImportError(_ error: Error) {
        alertTitle = "匯入失敗"
        alertMessage = error.localizedDescription
        showAlert = true
    }

    @ViewBuilder
    private var pinControls: some View {
        if !pairingExists {
            Text("請先在設定匯入配對檔，並連上 LocalDevVPN。")
                .font(.footnote)
                .foregroundStyle(.orange)
                .multilineTextAlignment(.leading)
        }
    }

    private var routeControls: some View {
        VStack(spacing: 12) {
            mapIconButton(
                systemImage: isRouteWalking ? "pause.fill" : "play.fill",
                tint: .accentColor,
                disabled: !pairingExists ||
                    isBusy ||
                    isLoadingRoute ||
                    isPrefetchingRouteSpeeds ||
                    routePlan == nil ||
                    routePlaybackSamples.isEmpty,
                label: isRouteWalking ? "暫停" : (isRoutePaused ? "繼續" : "開始路線"),
                action: toggleRoutePlayback
            )
        }
    }

    private var navigationDestinationName: String {
        let title = routeEndSelection?.title.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return title.isEmpty ? "目的地" : title
    }

    private var displayedSpeedKilometersPerHour: Int {
        max(0, Int(selectedPlanningSpeed.rounded()))
    }

    private var navigationDestinationBanner: some View {
        HStack(alignment: .center, spacing: 14) {
            Image(systemName: "arrow.triangle.turn.up.right.diamond.fill")
                .font(.system(size: 28, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 36)

            VStack(alignment: .leading, spacing: 3) {
                Text("前往")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.white.opacity(0.82))
                Text(navigationDestinationName)
                    .font(.title2.bold())
                    .foregroundStyle(.white)
                    .lineLimit(2)
                    .minimumScaleFactor(0.75)
            }

            Spacer(minLength: 8)
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            Color(red: 0.07, green: 0.42, blue: 0.26),
            in: RoundedRectangle(cornerRadius: 28, style: .continuous)
        )
        .shadow(color: .black.opacity(0.22), radius: 16, y: 6)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("前往\(navigationDestinationName)")
    }

    private var navigationSpeedometer: some View {
        ZStack {
            Circle()
                .fill(Color.white)
            Circle()
                .stroke(Color.black.opacity(0.08), lineWidth: 5)
                .padding(5)
            VStack(spacing: 0) {
                Text("\(displayedSpeedKilometersPerHour)")
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                    .foregroundStyle(.black)
                    .monospacedDigit()
                Text("km/h")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.black.opacity(0.45))
            }
        }
        .frame(width: 78, height: 78)
        .shadow(color: .black.opacity(0.2), radius: 8, y: 3)
        .accessibilityLabel("時速 \(displayedSpeedKilometersPerHour) 公里")
    }

    private var navigationBanner: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(remainingDurationText)
                    .font(.title.bold())
                    .minimumScaleFactor(0.7)
                    .lineLimit(1)
                Text("\(remainingDistanceText)  ．  \(arrivalTimeText)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            Button(action: endRouteNavigation) {
                Text("結束")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 22)
                    .padding(.vertical, 12)
                    .background(Color.red, in: Capsule())
            }
            .buttonStyle(.plain)
            .disabled(isBusy)
        }
        .padding(.leading, 20)
        .padding(.trailing, 12)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity)
        .background(Color(.systemBackground), in: RoundedRectangle(cornerRadius: 28, style: .continuous))
        .shadow(color: .black.opacity(0.16), radius: 14, y: 6)
        .accessibilityElement(children: .combine)
    }

    private func mapIconButton(
        systemImage: String,
        tint: Color,
        disabled: Bool,
        label: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.body.weight(.semibold))
                .foregroundStyle(disabled ? Color.secondary : tint)
                .frame(width: 44, height: 44)
                .background(.ultraThinMaterial, in: Circle())
                .shadow(color: .black.opacity(0.16), radius: 4, y: 2)
        }
        .disabled(disabled)
        .accessibilityLabel(label)
    }

    private func endRouteNavigation() {
        LocationSimulationControl.restoreRealLocation()
    }

    private func simulate() {
        guard pairingExists, let coord = coordinate, !isBusy else { return }
        runLocationCommand(
            errorTitle: "模擬失敗",
            errorMessage: { code in
                "無法模擬位置（錯誤 \(code)）。請確認裝置已連線，且位置模擬已就緒。"
            },
            operation: { locationUpdateCode(for: coord) }
        ) {
            routePlaybackCoordinate = nil
            beginBackgroundTask()
            LocationSimulationSession.shared.clearRoute()
            startResendLoop(with: coord)
        }
    }

    private func simulateRoute() {
        guard pairingExists,
              let routePlan,
              let firstCoordinate = routePlaybackSamples.first?.coordinate,
              !isBusy else {
            return
        }
        stopResendLoop()
        cancelRoutePlayback(resetMarker: false)
        runLocationCommand(
            errorTitle: "路線模擬失敗",
            errorMessage: { code in
                "無法開始路線模擬（錯誤 \(code)）。請確認裝置已連線，且位置模擬已就緒。"
            },
            operation: { locationUpdateCode(for: firstCoordinate) }
        ) {
            beginBackgroundTask()
            let routeID = LocationSimulationSession.shared.startRoute(
                at: firstCoordinate,
                coordinates: routePlan.displayCoordinates
            )
            simulatedCoordinate = nil
            isRoutePaused = false
            routePlaybackIndex = 0
            activeRouteID = routeID
            routePlaybackCoordinate = firstCoordinate
            isNavigationCameraFollowing = true
            navigationCamera.configure(samples: routePlaybackSamples)
            navigationCamera.isFollowing = true
            navigationCamera.start(fromElapsed: 0)
            syncSwiftUINavigationCamera(at: firstCoordinate, heading: navigationCamera.cameraHeading, animated: false)
            startRoutePlayback(routeID: routeID, fromIndex: 0)
            syncNavigationLiveActivity(force: true)
        }
    }

    private func toggleRoutePlayback() {
        if isRouteWalking {
            pauseRoutePlayback()
        } else if isRoutePaused {
            resumeRoutePlayback()
        } else {
            simulateRoute()
        }
    }

    private func pauseRoutePlayback() {
        guard isRouteWalking else { return }
        navigationCamera.pause()
        cancelRoutePlayback(resetMarker: false)
        isRoutePaused = true
        if let progress = playbackProgress(in: routePlaybackSamples, elapsed: navigationCamera.elapsed) {
            routePlaybackIndex = progress.index
            routePlaybackCoordinate = progress.coordinate
        }
        let pausedCoordinate = interpolatedPlaybackCoordinate() ?? displayedRouteCoordinate ?? routePlaybackCoordinate
        guard let pausedCoordinate else { return }
        LocationSimulationSession.shared.startResending(at: pausedCoordinate) {
            LocationSimulationCommandQueue.shared.async {
                _ = locationUpdateCode(for: pausedCoordinate)
            }
        }
        syncNavigationLiveActivity(force: true)
    }

    private func resumeRoutePlayback() {
        guard isRoutePaused, let routeID = activeRouteID else { return }
        LocationSimulationSession.shared.pauseResending()
        navigationCamera.resume()
        if let coordinate = interpolatedPlaybackCoordinate() ?? displayedRouteCoordinate ?? routePlaybackCoordinate {
            syncSwiftUINavigationCamera(
                at: coordinate,
                heading: navigationCamera.cameraHeading,
                animated: false
            )
        }
        startRoutePlayback(routeID: routeID, fromIndex: routePlaybackIndex)
        syncNavigationLiveActivity(force: true)
    }

    private func runLocationCommand(
        errorTitle: String,
        errorMessage: @escaping (Int32) -> String,
        operation: @escaping () -> Int32,
        onSuccess: @escaping () -> Void
    ) {
        isBusy = true
        LocationSimulationCommandQueue.shared.async {
            let code = operation()
            DispatchQueue.main.async {
                isBusy = false
                if code == 0 {
                    onSuccess()
                } else {
                    alertTitle = errorTitle
                    alertMessage = errorMessage(code)
                    showAlert = true
                }
            }
        }
    }

    private func resetSimulationUI() {
        cancelRoutePlayback(resetMarker: true)
        stopResendLoop()
        LocationSimulationSession.shared.clearRoute()
        resetRouteSelection()
        coordinate = nil
        simulatedCoordinate = nil
            endBackgroundTask()
        NavigationLiveActivityController.shared.end()
    }

    private func beginBackgroundTask() {
        guard backgroundTaskID == .invalid else { return }
        backgroundTaskID = UIApplication.shared.beginBackgroundTask { endBackgroundTask() }
    }

    private func endBackgroundTask() {
        guard backgroundTaskID != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTaskID)
        backgroundTaskID = .invalid
    }

    private func startResendLoop(with coordinate: CLLocationCoordinate2D) {
        simulatedCoordinate = coordinate
        LocationSimulationSession.shared.startResending(at: coordinate) {
            LocationSimulationCommandQueue.shared.async {
                _ = locationUpdateCode(for: coordinate)
            }
        }
    }

    private func stopResendLoop() {
        LocationSimulationSession.shared.pauseResending()
        simulatedCoordinate = nil
    }

    private func cancelRoutePlayback(resetMarker: Bool) {
        MovementStepInjector.shared.setMoving(false)
        routePlaybackTask?.cancel()
        routePlaybackTask = nil
        if resetMarker {
            navigationCamera.stop()
            routePlaybackCoordinate = nil
            routePlaybackIndex = 0
            activeRouteID = nil
            isRoutePaused = false
        }
    }

    private func applySelection(_ coordinate: CLLocationCoordinate2D, focusCamera: Bool = false) {
        guard CLLocationCoordinate2DIsValid(coordinate), !isNavigatingRoute else { return }
        if isPlanningRoute {
            isPlanningRoute = false
            directionsPlanner.reset()
        }
        if isRouteRunning || hasRouteContext {
            cancelRoutePlayback(resetMarker: true)
            stopResendLoop()
            resetRouteSelection()
        }
        self.coordinate = coordinate
        simulatedCoordinate = coordinate
        if focusCamera {
            position = .region(
                MKCoordinateRegion(
                    center: coordinate,
                    latitudinalMeters: 1000,
                    longitudinalMeters: 1000
                )
            )
        }
        if pairingExists, !isBusy {
            simulate()
        }
    }

    private func applySavedCoordinate(from notification: Notification) {
        guard let latitude = notification.userInfo?["latitude"] as? Double,
              let longitude = notification.userInfo?["longitude"] as? Double else {
            return
        }
        let coordinate = CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
        cancelRoutePlayback(resetMarker: true)
        stopResendLoop()
        resetRouteSelection()
        self.coordinate = coordinate
        simulatedCoordinate = coordinate
        position = .region(
            MKCoordinateRegion(
                center: coordinate,
                latitudinalMeters: 1000,
                longitudinalMeters: 1000
            )
        )
    }

    private func resetRouteSelection() {
        routeLoadTask?.cancel()
        routeLoadTask = nil
        routeSpeedPrefetchTask?.cancel()
        routeSpeedPrefetchTask = nil
        routeRequestID = UUID()
        setRoutePlan(nil)
        routeStartSelection = nil
        routeEndSelection = nil
        routePlaybackSamples = []
        routePlaybackCoordinate = nil
        routePlaybackIndex = 0
        activeRouteID = nil
        isRoutePaused = false
        shouldAutoStartRoute = false
        isLoadingRoute = false
        isPrefetchingRouteSpeeds = false
        isNavigationCameraFollowing = true
        routeModePreviews = [:]
        navigationCamera.stop()
        NavigationLiveActivityController.shared.end()
    }

    private func directionsRequest(
        from start: CLLocationCoordinate2D,
        to end: CLLocationCoordinate2D,
        mode: RouteNavigationMode
    ) -> MKDirections.Request {
        let request = MKDirections.Request()
        request.source = MKMapItem(placemark: MKPlacemark(coordinate: start))
        request.destination = MKMapItem(placemark: MKPlacemark(coordinate: end))
        request.requestsAlternateRoutes = true
        switch mode {
        case .automobile:
        request.transportType = .automobile
            request.highwayPreference = .avoid
        case .cycling:
            request.transportType = .cycling
        case .walking:
            request.transportType = .walking
        case .airplane:
            request.transportType = .any
        }
        return request
    }

    private func fetchRoutePreview(
        from start: CLLocationCoordinate2D,
        to end: CLLocationCoordinate2D,
        mode: RouteNavigationMode
    ) async throws -> RouteModePreview {
        if mode == .airplane {
            let distance = CLLocation(latitude: start.latitude, longitude: start.longitude)
                .distance(from: CLLocation(latitude: end.latitude, longitude: end.longitude))
            guard distance > 0 else {
                    throw NSError(
                        domain: "RouteSimulation",
                        code: -1,
                    userInfo: [NSLocalizedDescriptionKey: mode.missingRouteMessage]
                )
            }
            return RouteModePreview(
                distance: distance,
                displayCoordinates: geodesicCoordinates(
                    from: start,
                    to: end,
                    pointCount: RouteSimulationDefaults.airplaneDisplayPointCount
                ),
                isDirectPath: true
            )
        }

        let response = try await MKDirections(request: directionsRequest(from: start, to: end, mode: mode)).calculate()
        guard let route = response.routes.min(by: { $0.distance < $1.distance }) else {
            throw NSError(
                domain: "RouteSimulation",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: mode.missingRouteMessage]
            )
        }
        return RouteModePreview(
            distance: route.distance,
            displayCoordinates: sampledRouteCoordinates(
                    from: route.polyline.coordinateArray,
                    targetDistance: RouteSimulationDefaults.pathSamplingDistance
                )
        )
    }

    private func adoptRoutePreview(_ preview: RouteModePreview, requestID: UUID = UUID()) {
        routeRequestID = requestID
        setRoutePlan(
            RouteSimulationPlan(
                displayCoordinates: preview.displayCoordinates,
                distance: preview.distance,
                expectedTravelTime: preview.distance / RouteSimulationDefaults.metersPerSecond(for: selectedPlanningMode)
            )
        )
                    isLoadingRoute = false
                    if let routePolyline {
            focusCamera(on: routePolyline)
        }
        isPrefetchingRouteSpeeds = true
                    routeSpeedPrefetchTask?.cancel()
        let speed = RouteSimulationDefaults.metersPerSecond(for: selectedPlanningMode)
        let isDirectPath = preview.isDirectPath
        let startCoordinate = preview.displayCoordinates.first
        let endCoordinate = preview.displayCoordinates.last
                    routeSpeedPrefetchTask = Task.detached(priority: .utility) {
            let playbackSamples: [RoutePlaybackSample]
            if isDirectPath, let startCoordinate, let endCoordinate {
                playbackSamples = buildDirectPlaybackSamples(
                    from: startCoordinate,
                    to: endCoordinate,
                    speedMetersPerSecond: speed
                )
            } else {
                playbackSamples = await prefetchRoutePlaybackSamples(
                    displayCoordinates: preview.displayCoordinates,
                    fallbackSpeedMetersPerSecond: speed
                )
            }
                        guard !Task.isCancelled else { return }
                        await MainActor.run {
                            guard routeRequestID == requestID else { return }
                            routePlaybackSamples = playbackSamples
                            isPrefetchingRouteSpeeds = false
                if shouldAutoStartRoute {
                    shouldAutoStartRoute = false
                    simulateRoute()
                }
            }
        }
    }

    private func refreshRoute(autoStart: Bool = false) {
        routeLoadTask?.cancel()
        routeSpeedPrefetchTask?.cancel()
        routePlaybackSamples = []
        shouldAutoStartRoute = autoStart

        guard let routeStart = routeStartSelection?.coordinate,
              let routeEnd = routeEndSelection?.coordinate else {
            setRoutePlan(nil)
            routeModePreviews = [:]
            isLoadingRoute = false
            isPrefetchingRouteSpeeds = false
            shouldAutoStartRoute = false
            return
        }

        let requestID = UUID()
        routeRequestID = requestID
        isLoadingRoute = true
        isPrefetchingRouteSpeeds = false
        let selectedMode = RouteNavigationMode(rawValue: routeNavigationMode) ?? .defaultMode

        routeLoadTask = Task {
            do {
                var previews: [RouteNavigationMode: RouteModePreview] = [:]
                try await withThrowingTaskGroup(of: (RouteNavigationMode, RouteModePreview).self) { group in
                    for mode in RouteNavigationMode.allCases {
                        group.addTask {
                            let preview = try await self.fetchRoutePreview(from: routeStart, to: routeEnd, mode: mode)
                            return (mode, preview)
                        }
                    }
                    while let result = await group.nextResult() {
                        switch result {
                        case .success(let value):
                            previews[value.0] = value.1
                        case .failure:
                            break
                        }
                    }
                }
                guard !Task.isCancelled else { return }

                await MainActor.run {
                    guard routeRequestID == requestID else { return }
                    routeModePreviews = previews
                    if let preview = previews[selectedMode] ?? previews.values.first {
                        adoptRoutePreview(preview, requestID: requestID)
                    } else {
                        isLoadingRoute = false
                        isPrefetchingRouteSpeeds = false
                        shouldAutoStartRoute = false
                        setRoutePlan(nil)
                        alertTitle = "路線失敗"
                        alertMessage = selectedMode.missingRouteMessage
                        showAlert = true
                    }
                }
            } catch is CancellationError {
                await MainActor.run {
                    guard routeRequestID == requestID else { return }
                    isLoadingRoute = false
                    isPrefetchingRouteSpeeds = false
                    shouldAutoStartRoute = false
                }
            } catch {
                await MainActor.run {
                    guard routeRequestID == requestID else { return }
                    isLoadingRoute = false
                    isPrefetchingRouteSpeeds = false
                    shouldAutoStartRoute = false
                    setRoutePlan(nil)
                    routeModePreviews = [:]
                    alertTitle = "路線失敗"
                    alertMessage = error.localizedDescription
                    showAlert = true
                }
            }
        }
    }

    private func startRoutePlayback(routeID: UUID, fromIndex: Int = 0) {
        isRoutePaused = false
        activeRouteID = routeID
        MovementStepInjector.shared.setMoving(true)
        routePlaybackTask = Task {
            let clampedIndex = min(max(fromIndex, 0), max(routePlaybackSamples.count - 1, 0))
            var lastSuccessfulCoordinate = routePlaybackSamples.indices.contains(clampedIndex)
                ? routePlaybackSamples[clampedIndex].coordinate
                : routePlaybackSamples.first?.coordinate

            let nextIndex = min(clampedIndex + 1, routePlaybackSamples.count)
            for index in nextIndex..<routePlaybackSamples.count {
                let sample = routePlaybackSamples[index]
                try? await Task.sleep(for: .seconds(sample.delayFromPrevious))
                guard !Task.isCancelled,
                      LocationSimulationSession.shared.isCurrentRoute(routeID) else {
                    return
                }

                let code = await sendLocationUpdate(for: sample.coordinate)
                guard LocationSimulationSession.shared.isCurrentRoute(routeID) else { return }
                guard code == 0 else {
                    await MainActor.run {
                        MovementStepInjector.shared.setMoving(false)
                        navigationCamera.pause()
                        routePlaybackTask = nil
                        isRoutePaused = false
                        routePlaybackCoordinate = lastSuccessfulCoordinate
                        if let lastSuccessfulCoordinate {
                            startResendLoop(with: lastSuccessfulCoordinate)
                        }
                        alertTitle = "路線模擬失敗"
                        alertMessage = "無法繼續路線模擬（錯誤 \(code)）。"
                        showAlert = true
                    }
                    return
                }

                lastSuccessfulCoordinate = sample.coordinate
                await MainActor.run {
                    routePlaybackIndex = index
                    routePlaybackCoordinate = sample.coordinate
                    LocationSimulationSession.shared.updateCoordinate(sample.coordinate)
                    syncNavigationLiveActivity()
                }
            }

            await MainActor.run {
                guard LocationSimulationSession.shared.isCurrentRoute(routeID) else { return }
                MovementStepInjector.shared.setMoving(false)
                routePlaybackTask = nil
                isRoutePaused = false
                if let lastSuccessfulCoordinate {
                    routePlaybackIndex = max(routePlaybackSamples.count - 1, 0)
                    routePlaybackCoordinate = lastSuccessfulCoordinate
                    startResendLoop(with: lastSuccessfulCoordinate)
                    if let coordinate = interpolatedPlaybackCoordinate() {
                        syncSwiftUINavigationCamera(
                            at: coordinate,
                            heading: navigationCamera.cameraHeading,
                            animated: false
                        )
                    }
                }
                NavigationLiveActivityController.shared.end()
            }
        }
    }

    private func sendLocationUpdate(for coordinate: CLLocationCoordinate2D) async -> Int32 {
        await withCheckedContinuation { continuation in
            LocationSimulationCommandQueue.shared.async {
                continuation.resume(returning: locationUpdateCode(for: coordinate))
            }
        }
    }

    private func locationUpdateCode(for coordinate: CLLocationCoordinate2D) -> Int32 {
        simulate_location(deviceIP, coordinate.latitude, coordinate.longitude, pairingFilePath)
    }
}

@MainActor
private final class DirectionsPlannerModel: ObservableObject {
    @Published var startQuery = ""
    @Published var endQuery = ""
    @Published var startSelection: RouteSearchSelection?
    @Published var endSelection: RouteSearchSelection?
    @Published var focusedField: RouteSearchField?
    @Published var isResolving = false
    @Published var errorMessage: String?

    let startCompleter = LocationSearchCompleter()
    let endCompleter = LocationSearchCompleter()

    var activeResults: [MKLocalSearchCompletion] {
        switch focusedField {
        case .start:
            return startCompleter.results
        case .end:
            return endCompleter.results
        case .none:
            return []
        }
    }

    func begin(start: RouteSearchSelection?, end: RouteSearchSelection?) {
        startSelection = start
        endSelection = end
        startQuery = start?.title ?? ""
        endQuery = end?.title ?? ""
        errorMessage = nil
        isResolving = false
        focusedField = start == nil ? .start : .end
        startCompleter.update(query: "")
        endCompleter.update(query: "")
    }

    func reset() {
        startQuery = ""
        endQuery = ""
        startSelection = nil
        endSelection = nil
        focusedField = nil
        isResolving = false
        errorMessage = nil
        startCompleter.update(query: "")
        endCompleter.update(query: "")
    }

    func updateQuery(_ value: String, for field: RouteSearchField) {
        errorMessage = nil
        switch field {
        case .start:
            startQuery = value
            if value != startSelection?.title {
                startSelection = nil
            }
            startCompleter.update(query: value)
        case .end:
            endQuery = value
            if value != endSelection?.title {
                endSelection = nil
            }
            endCompleter.update(query: value)
        }
    }

    func swapEndpoints() {
        swap(&startQuery, &endQuery)
        swap(&startSelection, &endSelection)
        startCompleter.update(query: "")
        endCompleter.update(query: "")
    }

    func applyPicked(_ selection: RouteSearchSelection, field: RouteSearchField) {
        switch field {
        case .start:
            startSelection = selection
            startQuery = selection.title
            startCompleter.update(query: "")
            focusedField = endSelection == nil ? .end : nil
        case .end:
            endSelection = selection
            endQuery = selection.title
            endCompleter.update(query: "")
            focusedField = nil
        }
    }

    func resolve(_ completion: MKLocalSearchCompletion) {
        let field = focusedField ?? .end
        let request = MKLocalSearch.Request(completion: completion)
        isResolving = true
        errorMessage = nil

        MKLocalSearch(request: request).start { response, error in
            DispatchQueue.main.async {
                self.isResolving = false
                guard let item = response?.mapItems.first else {
                    self.errorMessage = error?.localizedDescription ?? "找不到這個地點。"
                    return
                }
                let name = item.name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let title = name.isEmpty ? completion.title : name
                self.applyPicked(
                    RouteSearchSelection(title: title, coordinate: item.placemark.coordinate),
                    field: field
                )
            }
        }
    }
}

private struct DirectionsHeaderCard: View {
    @ObservedObject var planner: DirectionsPlannerModel
    @ObservedObject private var startCompleter: LocationSearchCompleter
    @ObservedObject private var endCompleter: LocationSearchCompleter
    @FocusState private var focusedField: RouteSearchField?
    let onClose: () -> Void

    init(planner: DirectionsPlannerModel, onClose: @escaping () -> Void) {
        self.planner = planner
        self._startCompleter = ObservedObject(wrappedValue: planner.startCompleter)
        self._endCompleter = ObservedObject(wrappedValue: planner.endCompleter)
        self.onClose = onClose
    }

    var body: some View {
        VStack(spacing: 8) {
            HStack(alignment: .top, spacing: 10) {
                VStack(spacing: 0) {
                    Circle()
                        .fill(Color.blue)
                        .frame(width: 10, height: 10)
                        .padding(.top, 16)
                    Rectangle()
                        .fill(Color.secondary.opacity(0.35))
                        .frame(width: 2, height: 28)
                    Circle()
                        .stroke(Color.red, lineWidth: 2.5)
                        .frame(width: 10, height: 10)
                }

                VStack(spacing: 0) {
                    plannerField(placeholder: "你的位置", field: .start)
                    Divider()
                    plannerField(placeholder: "選擇目的地", field: .end)
                }

                VStack(spacing: 10) {
                    Button(action: onClose) {
                        Image(systemName: "xmark")
                            .font(.body.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: 28, height: 28)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("關閉")

                    Button {
                        planner.swapEndpoints()
                    } label: {
                        Image(systemName: "arrow.up.arrow.down")
                            .font(.body.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: 28, height: 28)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("對調起點與終點")
                }
                .padding(.top, 4)
            }
            .padding(.leading, 16)
            .padding(.trailing, 10)
            .padding(.vertical, 6)
            .background(Color(.systemBackground), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .shadow(color: .black.opacity(0.14), radius: 12, y: 4)

            if planner.isResolving || !visibleResults.isEmpty {
                searchResults
            }

            if let errorMessage = planner.errorMessage {
                    Text(errorMessage)
                        .font(.footnote)
                        .foregroundStyle(.red)
                    .padding(.horizontal, 4)
            }
        }
        .onAppear {
            focusedField = planner.focusedField ?? (planner.startSelection == nil ? .start : .end)
        }
        .onChange(of: focusedField) { _, newValue in
            planner.focusedField = newValue
        }
        .onChange(of: planner.focusedField) { _, newValue in
            if focusedField != newValue {
                focusedField = newValue
            }
        }
    }

    private var visibleResults: [MKLocalSearchCompletion] {
        switch focusedField ?? planner.focusedField {
        case .start:
            return Array(startCompleter.results.prefix(6))
        case .end:
            return Array(endCompleter.results.prefix(6))
        case .none:
            return []
        }
    }

    private var searchResults: some View {
        VStack(alignment: .leading, spacing: 0) {
            if planner.isResolving {
                HStack(spacing: 8) {
                    ProgressView()
                    Text("正在解析地點…")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .padding(14)
            } else {
                ForEach(Array(visibleResults.enumerated()), id: \.offset) { index, result in
                                Button {
                        planner.resolve(result)
                                } label: {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(result.title)
                                            .font(.subheadline)
                                            .foregroundStyle(.primary)
                                        if !result.subtitle.isEmpty {
                                            Text(result.subtitle)
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                        }
                                    }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 11)
                        .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)

                    if index < visibleResults.count - 1 {
                        Divider().padding(.leading, 14)
                    }
                }
            }
        }
        .background(Color(.systemBackground), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .shadow(color: .black.opacity(0.12), radius: 12, y: 4)
    }

    private func plannerField(placeholder: String, field: RouteSearchField) -> some View {
        TextField(placeholder, text: Binding(
            get: { field == .start ? planner.startQuery : planner.endQuery },
            set: { planner.updateQuery($0, for: field) }
        ))
                    .textInputAutocapitalization(.words)
                    .autocorrectionDisabled()
                    .focused($focusedField, equals: field)
                    .submitLabel(field == .start ? .next : .done)
        .padding(.vertical, 12)
                    .onSubmit {
            focusedField = field == .start ? .end : nil
        }
    }
}

private struct DirectionsModeBar: View {
    @Binding var selectedMode: RouteNavigationMode
    let modePreviews: [RouteNavigationMode: RouteModePreview]
    let selectedPreview: RouteModePreview?
    let speedKilometersPerHour: Double
    let isLoading: Bool
    let canStart: Bool
    let onStart: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 6) {
                ForEach(RouteNavigationMode.allCases) { mode in
                    Button {
                        selectedMode = mode
                    } label: {
                        VStack(spacing: 3) {
                            Image(systemName: mode.systemImage)
                                .font(.subheadline.weight(.semibold))
                            Text(modeTimeText(for: mode))
                                .font(.caption2.weight(.semibold))
                                .lineLimit(1)
                                .minimumScaleFactor(0.7)
                        }
                        .foregroundStyle(selectedMode == mode ? Color.white : Color.primary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background(
                            selectedMode == mode ? Color.accentColor : Color(.secondarySystemFill),
                            in: RoundedRectangle(cornerRadius: 14, style: .continuous)
                        )
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(mode.title)
                }
            }

            if isLoading && selectedPreview == nil {
                ProgressView("正在規劃路線…")
                    .font(.subheadline)
            } else if let selectedPreview {
                VStack(alignment: .leading, spacing: 3) {
                    Text(formatRouteTravelTime(selectedPreview.travelTime(kilometersPerHour: speedKilometersPerHour)))
                        .font(.title2.bold())
                    Text("\(formatRouteDistance(selectedPreview.distance)) · \(Int(speedKilometersPerHour.rounded())) km/h")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            } else {
                Text("輸入目的地後即可預覽路線")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Button(action: onStart) {
                Label("開始", systemImage: "arrow.triangle.turn.up.right.diamond.fill")
                    .font(.title3.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 13)
            }
            .buttonStyle(.borderedProminent)
            .disabled(!canStart)
        }
        .padding(16)
        .background(Color(.systemBackground), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .shadow(color: .black.opacity(0.14), radius: 12, y: 4)
    }

    private func modeTimeText(for mode: RouteNavigationMode) -> String {
        if let preview = modePreviews[mode] {
            return formatRouteTravelTime(
                preview.travelTime(kilometersPerHour: RouteSimulationSpeed.kilometersPerHour(for: mode))
            )
        }
        return mode.title
    }
}

// MARK: - Bookmarks Sheet

struct BookmarksView: View {
    @Binding var bookmarks: [LocationBookmark]
    var currentCoordinate: CLLocationCoordinate2D?
    let onSelect: (LocationBookmark) -> Void
    let onDelete: (IndexSet) -> Void
    let onAdd: (String, CLLocationCoordinate2D) -> Void

    @State private var showSaveBookmark = false
    @State private var newBookmarkName = ""
    @State private var showNeedLocation = false

    var body: some View {
        NavigationStack {
            Group {
                if bookmarks.isEmpty {
                    ContentUnavailableView(
                        "尚無書籤",
                        systemImage: "bookmark.slash",
                        description: Text("在地圖上放圖釘後，點左上角「新增」即可儲存。")
                    )
                } else {
                    List {
                        ForEach(bookmarks) { bookmark in
                            Button {
                                onSelect(bookmark)
                            } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(bookmark.name)
                                        .foregroundStyle(.primary)
                                    Text(String(format: "%.6f, %.6f", bookmark.latitude, bookmark.longitude))
                                        .font(.caption.monospaced())
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                        .onDelete(perform: onDelete)
                    }
                }
            }
            .navigationTitle("書籤")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("新增") {
                        if currentCoordinate != nil {
                            newBookmarkName = ""
                            showSaveBookmark = true
                        } else {
                            showNeedLocation = true
                        }
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    EditButton()
                }
            }
            .alert("儲存書籤", isPresented: $showSaveBookmark) {
                TextField("名稱", text: $newBookmarkName)
                Button("儲存") {
                    if let currentCoordinate {
                        onAdd(newBookmarkName, currentCoordinate)
                    }
                    newBookmarkName = ""
                }
                Button("取消", role: .cancel) {
                    newBookmarkName = ""
                }
            } message: {
                Text("為此位置取一個名稱。")
            }
            .alert("無法新增", isPresented: $showNeedLocation) {
                Button("確定", role: .cancel) { }
            } message: {
                Text("請先在地圖上放圖釘，再儲存書籤。")
            }
        }
    }
}

private struct RouteMapCanvas: View, Equatable {
    @Binding var position: MapCameraPosition
    let hasRouteContext: Bool
    let isNavigatingRoute: Bool
    let routeCoordinates: [CLLocationCoordinate2D]?
    let routeStart: CLLocationCoordinate2D?
    let routeEnd: CLLocationCoordinate2D?
    let pinCoordinate: CLLocationCoordinate2D?
    let displayedRouteCoordinate: CLLocationCoordinate2D?
    let onTap: (CLLocationCoordinate2D) -> Void
    let onUnlock: () -> Void

    static func == (lhs: RouteMapCanvas, rhs: RouteMapCanvas) -> Bool {
        lhs.hasRouteContext == rhs.hasRouteContext &&
        lhs.isNavigatingRoute == rhs.isNavigatingRoute &&
        lhs.routeCoordinates?.count == rhs.routeCoordinates?.count &&
        lhs.routeCoordinates?.first.map(CoordinateSnapshot.init) == rhs.routeCoordinates?.first.map(CoordinateSnapshot.init) &&
        lhs.routeCoordinates?.last.map(CoordinateSnapshot.init) == rhs.routeCoordinates?.last.map(CoordinateSnapshot.init) &&
        lhs.routeStart.map(CoordinateSnapshot.init) == rhs.routeStart.map(CoordinateSnapshot.init) &&
        lhs.routeEnd.map(CoordinateSnapshot.init) == rhs.routeEnd.map(CoordinateSnapshot.init) &&
        lhs.pinCoordinate.map(CoordinateSnapshot.init) == rhs.pinCoordinate.map(CoordinateSnapshot.init) &&
        lhs.displayedRouteCoordinate.map(CoordinateSnapshot.init) == rhs.displayedRouteCoordinate.map(CoordinateSnapshot.init)
    }

    var body: some View {
        MapReader { proxy in
            Map(position: $position) {
                if !isNavigatingRoute {
                    UserAnnotation()
                }
                if hasRouteContext {
                    if let routeCoordinates, routeCoordinates.count > 1 {
                        MapPolyline(coordinates: routeCoordinates)
                            .stroke(.blue.opacity(0.85), lineWidth: 5)
                    }
                    if let routeStart {
                        Marker("起點", coordinate: routeStart)
                            .tint(.green)
                    }
                    if let routeEnd {
                        Marker("終點", coordinate: routeEnd)
                            .tint(.red)
                    }
                    if !isNavigatingRoute, let displayedRouteCoordinate {
                        Marker("目前位置", coordinate: displayedRouteCoordinate)
                            .tint(.blue)
                    }
                } else if let pinCoordinate {
                    Marker("圖釘", coordinate: pinCoordinate)
                        .tint(.red)
                }
            }
            .mapStyle(.standard(elevation: .flat))
            .onTapGesture { point in
                guard !isNavigatingRoute, let loc = proxy.convert(point, from: .local) else { return }
                onTap(loc)
            }
            .simultaneousGesture(
                DragGesture(minimumDistance: 12)
                    .onChanged { _ in onUnlock() }
            )
            .simultaneousGesture(
                MagnificationGesture()
                    .onChanged { _ in onUnlock() }
            )
            .simultaneousGesture(
                RotationGesture()
                    .onChanged { _ in onUnlock() }
            )
            .mapControlVisibility(.hidden)
        }
    }
}

private func findNearbyMKMapView(startingFrom view: UIView) -> MKMapView? {
    var current: UIView? = view
    var depth = 0
    while let node = current, depth < 8 {
        if let mapView = liveMapView(node) {
            return mapView
        }
        if let parent = node.superview {
            if let mapView = liveMapView(parent) {
                return mapView
            }
            for sibling in parent.subviews where sibling !== node {
                if let mapView = liveMapView(sibling) ?? searchNearbyMKMapView(sibling, remaining: 3) {
                    return mapView
                }
            }
        }
        current = node.superview
        depth += 1
    }
    return nil
}

private func liveMapView(_ view: UIView) -> MKMapView? {
    guard let mapView = view as? MKMapView, mapView.window != nil else {
        return nil
    }
    return mapView
}

private func searchNearbyMKMapView(_ root: UIView, remaining: Int) -> MKMapView? {
    if let mapView = liveMapView(root) {
        return mapView
    }
    guard remaining > 0 else { return nil }
    for subview in root.subviews {
        if let mapView = searchNearbyMKMapView(subview, remaining: remaining - 1) {
            return mapView
        }
    }
    return nil
}

private func applyFlatMapAppearance(to mapView: MKMapView) {
    if mapView.showsBuildings {
        mapView.showsBuildings = false
    }
    if let configuration = mapView.preferredConfiguration as? MKStandardMapConfiguration {
        if configuration.elevationStyle != .flat {
            configuration.elevationStyle = .flat
        }
    } else {
        mapView.preferredConfiguration = MKStandardMapConfiguration(elevationStyle: .flat)
    }
}

private final class NavigationPuckView: UIView {
    static let puckSize = CGSize(width: 64, height: 64)

    override init(frame: CGRect) {
        super.init(frame: CGRect(origin: .zero, size: Self.puckSize))
        isOpaque = false
        backgroundColor = .clear
        isUserInteractionEnabled = false
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.34
        layer.shadowRadius = 3.5
        layer.shadowOffset = CGSize(width: 0, height: 2)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func draw(_ rect: CGRect) {
        let halo = UIBezierPath(ovalIn: rect.insetBy(dx: 4, dy: 4))
        UIColor.systemBlue.withAlphaComponent(0.2).setFill()
        halo.fill()

        let path = UIBezierPath()
        path.move(to: CGPoint(x: rect.midX, y: rect.minY + 8))
        path.addLine(to: CGPoint(x: rect.maxX - 11, y: rect.maxY - 11))
        path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY - 19))
        path.addLine(to: CGPoint(x: rect.minX + 11, y: rect.maxY - 11))
        path.close()

        UIColor(red: 66 / 255, green: 133 / 255, blue: 244 / 255, alpha: 1).setFill()
        UIColor.white.setStroke()
        path.lineWidth = 3.2
        path.lineJoinStyle = .round
        path.lineCapStyle = .round
        path.fill()
        path.stroke()
    }
}

private final class NavigationCameraSession {
    var samples: [RoutePlaybackSample] = []
    var isWalking = false
    var isFollowing = true
    var cameraHeading: CLLocationDirection = 0

    private var elapsedOffset: TimeInterval = 0
    private var walkingStartedAt: Date?
    private var hasHeading = false
    private var puckView: NavigationPuckView?
    private var lastAppliedHeading: CLLocationDirection?
    private var lastAppliedCoordinate: CLLocationCoordinate2D?
    private var lastPuckPoint: CGPoint?
    private var lastPuckRotation: CGFloat?

    var elapsed: TimeInterval {
        let live = walkingStartedAt.map { Date().timeIntervalSince($0) } ?? 0
        return max(0, elapsedOffset + live)
    }

    var totalDuration: TimeInterval {
        samples.dropFirst().reduce(0) { $0 + $1.delayFromPrevious }
    }

    var currentCoordinate: CLLocationCoordinate2D? {
        playbackProgress(in: samples, elapsed: min(elapsed, totalDuration))?.coordinate
    }

    var needsMapAttachment: Bool {
        mapView == nil || mapView?.window == nil || overlay == nil || overlay?.window == nil
    }

    func configure(samples: [RoutePlaybackSample]) {
        self.samples = samples
    }

    func start(fromElapsed startElapsed: TimeInterval) {
        elapsedOffset = startElapsed
        walkingStartedAt = Date()
        isWalking = true
        hasHeading = false
        prepareHeading()
    }

    func pause() {
        elapsedOffset = elapsed
        walkingStartedAt = nil
        isWalking = false
    }

    func resume() {
        walkingStartedAt = Date()
        isWalking = true
    }

    func stop() {
        isWalking = false
        walkingStartedAt = nil
        elapsedOffset = 0
        hasHeading = false
        cameraHeading = 0
        samples = []
        lastAppliedHeading = nil
        lastAppliedCoordinate = nil
        lastPuckPoint = nil
        lastPuckRotation = nil
        hidePuck()
    }

    func hidePuck() {
        puckView?.removeFromSuperview()
        puckView = nil
        lastPuckPoint = nil
        lastPuckRotation = nil
    }

    func detach() {
        hidePuck()
        mapView = nil
        overlay = nil
    }

    func snapAndApply() {
        hasHeading = false
        lastAppliedHeading = nil
        lastAppliedCoordinate = nil
        lastPuckPoint = nil
        lastPuckRotation = nil
        prepareHeading()
        apply(dt: 1)
    }

    func apply(dt: CFTimeInterval) {
        updateHeading(dt: dt)
        guard isFollowing, let mapView, mapView.window != nil, let coordinate = currentCoordinate else {
            updatePuck()
            return
        }
        guard CLLocationCoordinate2DIsValid(coordinate), cameraHeading.isFinite else {
            updatePuck()
            return
        }

        if let lastHeading = lastAppliedHeading, let lastCoordinate = lastAppliedCoordinate {
            var headingDelta = abs(cameraHeading - lastHeading)
            if headingDelta > 180 { headingDelta = 360 - headingDelta }
            let moved = CLLocation(latitude: lastCoordinate.latitude, longitude: lastCoordinate.longitude)
                .distance(from: CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude))
            if headingDelta < 0.02, moved < 0.04 {
                updatePuck()
                return
            }
        }

        lastAppliedHeading = cameraHeading
        lastAppliedCoordinate = coordinate

        let center = coordinateByMoving(
            coordinate,
            distance: RouteSimulationDefaults.navigationCenterOffset,
            heading: cameraHeading
        )
        guard CLLocationCoordinate2DIsValid(center) else {
            updatePuck()
            return
        }
        let camera = MKMapCamera(
            lookingAtCenter: center,
            fromDistance: RouteSimulationDefaults.navigationCameraDistance,
            pitch: RouteSimulationDefaults.navigationCameraPitch,
            heading: cameraHeading
        )
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        mapView.camera = camera
        CATransaction.commit()
        updatePuck()
    }

    private weak var mapView: MKMapView?
    private weak var overlay: UIView?

    func attach(mapView: MKMapView?, overlay: UIView?) {
        let mapChanged = self.mapView !== mapView
        let overlayChanged = self.overlay !== overlay
        if mapChanged || overlayChanged {
            hidePuck()
        }
        self.mapView = mapView
        self.overlay = overlay
        if let mapView {
            applyFlatMapAppearance(to: mapView)
        }
    }

    private func updateHeading(dt: CFTimeInterval) {
        guard let targetHeading = polylineTangentHeading(in: samples, elapsed: min(elapsed, totalDuration)) else {
            return
        }
        if hasHeading {
            let alpha = 1 - exp(-max(dt, 1.0 / 120.0) / RouteSimulationDefaults.navigationHeadingSmoothingTime)
            cameraHeading = interpolateHeading(from: cameraHeading, to: targetHeading, fraction: min(1, alpha))
        } else {
            cameraHeading = targetHeading
            hasHeading = true
        }
    }

    private func updatePuck() {
        guard let mapView, mapView.window != nil,
              let overlay, overlay.window != nil,
              let coordinate = currentCoordinate else {
            puckView?.isHidden = true
            return
        }

        let puck = ensurePuck(on: overlay)
        let point = mapView.convert(coordinate, toPointTo: overlay)
        guard point.x.isFinite, point.y.isFinite else { return }
        let rotation = CGFloat((cameraHeading - mapView.camera.heading) * .pi / 180)
        lastPuckPoint = point
        lastPuckRotation = rotation
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        puck.isHidden = false
        puck.center = point
        puck.transform = CGAffineTransform(rotationAngle: rotation)
        CATransaction.commit()
    }

    private func ensurePuck(on overlay: UIView) -> NavigationPuckView {
        if let puckView, puckView.superview === overlay {
            return puckView
        }
        hidePuck()
        let puck = NavigationPuckView()
        puck.layer.zPosition = 10_000
        overlay.addSubview(puck)
        puckView = puck
        return puck
    }

    private func prepareHeading() {
        guard let targetHeading = polylineTangentHeading(in: samples, elapsed: min(elapsed, totalDuration)) else {
            return
        }
        cameraHeading = targetHeading
        hasHeading = true
    }
}

private struct NavigationCameraBridge: UIViewRepresentable {
    let session: NavigationCameraSession
    let isNavigating: Bool

    func makeUIView(context: Context) -> NavigationCameraBridgeView {
        let view = NavigationCameraBridgeView()
        view.session = session
        return view
    }

    func updateUIView(_ uiView: NavigationCameraBridgeView, context: Context) {
        uiView.session = session
        uiView.setNavigating(isNavigating)
    }

    static func dismantleUIView(_ uiView: NavigationCameraBridgeView, coordinator: ()) {
        uiView.setNavigating(false)
    }
}

private final class NavigationCameraDisplayLinkProxy {
    weak var owner: NavigationCameraBridgeView?

    @objc func tick(_ link: CADisplayLink) {
        owner?.handleDisplayTick(link)
    }
}

private final class NavigationCameraBridgeView: UIView {
    var session: NavigationCameraSession?
    private var isNavigating = false
    private var displayLink: CADisplayLink?
    private let displayLinkProxy = NavigationCameraDisplayLinkProxy()
    private var lastTimestamp: CFTimeInterval = 0

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        backgroundColor = .clear
        clipsToBounds = false
        displayLinkProxy.owner = self
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        displayLink?.invalidate()
    }

    func setNavigating(_ isNavigating: Bool) {
        let becameNavigating = isNavigating && !self.isNavigating
        let becameIdle = !isNavigating && self.isNavigating
        self.isNavigating = isNavigating
        if becameIdle {
            session?.detach()
            stopDisplayLink()
            return
        }
        guard isNavigating else { return }
        if becameNavigating || session?.needsMapAttachment == true {
            applyFlatMapAppearanceIfNeeded()
            attachMapView()
        }
        startDisplayLink()
        if becameNavigating {
            session?.apply(dt: 1.0 / 30.0)
        }
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil {
            session?.detach()
            stopDisplayLink()
            return
        }
        applyFlatMapAppearanceIfNeeded()
        guard isNavigating else { return }
        attachMapView()
        startDisplayLink()
        session?.apply(dt: 1.0 / 15.0)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        applyFlatMapAppearanceIfNeeded()
        guard isNavigating else { return }
        attachMapView()
    }

    private func applyFlatMapAppearanceIfNeeded() {
        guard let mapView = findNearbyMKMapView(startingFrom: self) else { return }
        applyFlatMapAppearance(to: mapView)
    }

    private func attachMapView() {
        session?.attach(mapView: findNearbyMKMapView(startingFrom: self), overlay: self)
    }

    private func startDisplayLink() {
        guard displayLink == nil else { return }
        lastTimestamp = 0
        let link = CADisplayLink(target: displayLinkProxy, selector: #selector(NavigationCameraDisplayLinkProxy.tick(_:)))
        let isPad = UIDevice.current.userInterfaceIdiom == .pad
        let preferred: Float = isPad ? 24 : 30
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 20, maximum: preferred, preferred: preferred)
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    private func stopDisplayLink() {
        displayLink?.invalidate()
        displayLink = nil
        lastTimestamp = 0
    }

    func handleDisplayTick(_ link: CADisplayLink) {
        if session?.needsMapAttachment == true {
            attachMapView()
        }
        let raw = lastTimestamp == 0 ? max(link.duration, 1.0 / 30.0) : (link.timestamp - lastTimestamp)
        lastTimestamp = link.timestamp
        session?.apply(dt: min(max(raw, 1.0 / 120.0), 1.0 / 12.0))
    }
}

private struct AppleMapsCompass: UIViewRepresentable {
    func makeUIView(context: Context) -> AppleMapsCompassView {
        AppleMapsCompassView()
    }

    func updateUIView(_ uiView: AppleMapsCompassView, context: Context) {
        uiView.attachToMapIfNeeded()
    }
}

private final class AppleMapsCompassView: UIView {
    private var compassButton: MKCompassButton?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isUserInteractionEnabled = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var intrinsicContentSize: CGSize {
        CGSize(width: 40, height: 40)
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        attachToMapIfNeeded()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        attachToMapIfNeeded()
    }

    func attachToMapIfNeeded() {
        guard let mapView = findNearbyMKMapView(startingFrom: self) else { return }
        mapView.showsCompass = false

        if compassButton == nil {
            let button = MKCompassButton(mapView: mapView)
            button.compassVisibility = .visible
            button.translatesAutoresizingMaskIntoConstraints = false
            addSubview(button)
            NSLayoutConstraint.activate([
                button.centerXAnchor.constraint(equalTo: centerXAnchor),
                button.centerYAnchor.constraint(equalTo: centerYAnchor)
            ])
            compassButton = button
        } else if compassButton?.mapView !== mapView {
            compassButton?.mapView = mapView
        }
    }
}
