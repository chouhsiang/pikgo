import SwiftUI
import CoreLocation

struct SavedCoordinatesView: View {
    @ObservedObject private var catalog = RemoteLocationCatalog.shared
    @ObservedObject private var simulationSession = LocationSimulationSession.shared
    @AppStorage("primaryTabSelection") private var tabSelection = AppFeature.status.id
    @State private var isSimulating = false
    @State private var selectedPlaceID: String?
    @State private var expandedCountryIDs: Set<String> = []

    var body: some View {
        NavigationStack {
            Group {
                if catalog.isEmpty, catalog.isLoading {
                    ProgressView("正在載入座標…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if catalog.isEmpty {
                    ContentUnavailableView {
                        Label("沒有座標", systemImage: "mappin.slash")
                    } description: {
                        Text(catalog.errorMessage ?? "目前沒有可選的座標。")
                    } actions: {
                        Button("重新載入") {
                            Task { await catalog.refresh() }
                        }
                    }
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 24) {
                            if let errorMessage = catalog.errorMessage {
                                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                                    .font(.footnote)
                                    .foregroundStyle(.orange)
                            }

                            if !catalog.countries.isEmpty {
                                VStack(alignment: .leading, spacing: 8) {
                                    Text("城市")
                                        .font(.footnote.weight(.medium))
                                        .foregroundStyle(.secondary)

                                    TimelineView(.periodic(from: .now, by: 30)) { context in
                                        VStack(spacing: 6) {
                                            ForEach(catalog.countries) { country in
                                                countryCard(country, now: context.date)
                                            }
                                        }
                                    }
                                }
                            }

                            ForEach(catalog.sections) { section in
                                VStack(alignment: .leading, spacing: 8) {
                                    Text(section.title)
                                        .font(.footnote.weight(.medium))
                                        .foregroundStyle(.secondary)

                                    placePills(section.places)
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                    }
                    .refreshable {
                        await catalog.refresh()
                    }
                }
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("座標")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    if catalog.isLoading || isSimulating {
                        ProgressView()
                    } else {
                        Button {
                            Task { await catalog.refresh() }
                        } label: {
                            Image(systemName: "arrow.clockwise")
                        }
                        .accessibilityLabel("重新載入")
                    }
                }
            }
            .task {
                await catalog.refresh()
            }
        }
    }

    @ViewBuilder
    private func countryCard(_ country: LocationCatalogCountry, now: Date) -> some View {
        let isExpanded = expandedCountryIDs.contains(country.id)
        let isCurrent = country.matchesCurrentTimeZone
        let timeZone = country.representativeTimeZone

        VStack(spacing: 0) {
            Button {
                if country.isSingleCity, let city = country.cities.first {
                    simulate(city.asPlace)
                } else {
                    toggleCountry(country.id)
                }
            } label: {
                HStack(spacing: 8) {
                    Text(country.flag)
                        .font(.title3)
                    Text(country.name)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                    Spacer(minLength: 8)
                    Image(systemName: LocationTimeDisplay.isDaytime(timeZone, at: now) ? "sun.max.fill" : "moon.fill")
                        .font(.caption)
                        .foregroundStyle(LocationTimeDisplay.isDaytime(timeZone, at: now) ? .orange : .indigo)
                    Text(LocationTimeDisplay.localTimeText(timeZone, at: now))
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(.secondary)
                    if isCurrent {
                        Text("現在")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.yellow)
                    } else {
                        Text(LocationTimeDisplay.offsetText(from: timeZone, at: now))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    if !country.isSingleCity {
                        Image(systemName: "chevron.down")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.tertiary)
                            .rotationEffect(.degrees(isExpanded ? 180 : 0))
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(isSimulating)

            if isExpanded, !country.isSingleCity {
                placePills(country.cities.map(\.asPlace))
                    .padding(.horizontal, 12)
                    .padding(.bottom, 10)
            }
        }
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(isCurrent ? Color.yellow.opacity(0.45) : Color.clear, lineWidth: 1)
        }
    }

    private func placePills(_ places: [LocationCatalogPlace]) -> some View {
        FlowLayout(spacing: 6) {
            ForEach(places) { place in
                Button {
                    simulate(place)
                } label: {
                    Text(place.name)
                        .font(.subheadline.weight(.medium))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(
                            isSelected(place)
                                ? Color.accentColor
                                : Color(.secondarySystemFill),
                            in: Capsule()
                        )
                        .foregroundStyle(isSelected(place) ? Color.white : Color.primary)
                }
                .buttonStyle(.plain)
                .disabled(isSimulating)
            }
        }
    }

    private func toggleCountry(_ id: String) {
        if expandedCountryIDs.contains(id) {
            expandedCountryIDs.remove(id)
        } else {
            expandedCountryIDs.insert(id)
        }
    }

    private func isSelected(_ place: LocationCatalogPlace) -> Bool {
        if selectedPlaceID == place.id {
            return true
        }
        guard let current = simulationSession.coordinate else { return false }
        return abs(current.latitude - place.coordinate.latitude) < 0.000001
            && abs(current.longitude - place.coordinate.longitude) < 0.000001
    }

    private func simulate(_ place: LocationCatalogPlace) {
        guard !isSimulating else { return }
        isSimulating = true
        selectedPlaceID = place.id
        tabSelection = AppFeature.location.id
        LocationSimulationControl.simulateCoordinate(place.coordinate) { result in
            isSimulating = false
            switch result {
            case .success:
                break
            case .missingPairing:
                presentAlert(title: "需要配對檔", message: "請先匯入這台裝置的配對檔，才能模擬位置。")
            case .failed(let code):
                presentAlert(
                    title: "模擬失敗",
                    message: "無法模擬位置（錯誤 \(code)）。請確認裝置已連線，且位置模擬已就緒。"
                )
            }
        }
    }

    private func presentAlert(title: String, message: String) {
        showAlert(title: title, message: message, showOk: true)
    }
}

private struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        layout(in: proposal.replacingUnspecifiedDimensions().width, subviews: subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = layout(in: bounds.width, subviews: subviews)
        for (index, origin) in result.origins.enumerated() {
            subviews[index].place(
                at: CGPoint(x: bounds.minX + origin.x, y: bounds.minY + origin.y),
                proposal: .unspecified
            )
        }
    }

    private func layout(in width: CGFloat, subviews: Subviews) -> (size: CGSize, origins: [CGPoint]) {
        var origins: [CGPoint] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var maxX: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            origins.append(CGPoint(x: x, y: y))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
            maxX = max(maxX, x - spacing)
        }

        return (CGSize(width: max(maxX, width), height: y + rowHeight), origins)
    }
}
