import SwiftUI

struct CatalogSidebar: View {
    @Bindable var store: PerihelionStore

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            brand
            search
            filter

            ScrollView {
                LazyVStack(spacing: 9) {
                    ForEach(store.filteredWorlds) { world in
                        CandidateRow(
                            world: world,
                            isSelected: store.selectedWorldID == world.id,
                            select: { store.select(world) },
                            togglePin: { store.togglePinned(world) }
                        )
                    }

                    if store.filteredWorlds.isEmpty {
                        ContentUnavailableView(
                            "No matching worlds",
                            systemImage: "sparkle.magnifyingglass",
                            description: Text("Try another system, class, or signal tag.")
                        )
                        .padding(.vertical, 28)
                    }
                }
            }
            .scrollIndicators(.hidden)

            archiveStatus
        }
        .padding(22)
        .frame(width: 292)
        .background(
            LinearGradient(
                colors: [
                    PerihelionPalette.midnight.opacity(0.98),
                    PerihelionPalette.void.opacity(0.94),
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        )
        .overlay(alignment: .trailing) {
            Rectangle()
                .fill(Color.white.opacity(0.08))
                .frame(width: 1)
        }
    }

    private var brand: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .stroke(PerihelionPalette.amber.opacity(0.36), lineWidth: 1)
                    .frame(width: 41, height: 41)
                Circle()
                    .fill(PerihelionPalette.amber)
                    .frame(width: 12, height: 12)
                    .shadow(color: PerihelionPalette.amber, radius: 9)
                Circle()
                    .fill(PerihelionPalette.cyan)
                    .frame(width: 5, height: 5)
                    .offset(x: 18, y: -7)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text("PERIHELION")
                    .font(.system(size: 16, weight: .bold, design: .rounded))
                    .tracking(1.4)
                Text("Deep-sky observation desk")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var search: some View {
        HStack(spacing: 9) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(PerihelionPalette.cyan)
            TextField("Search the catalog", text: $store.searchText)
                .textFieldStyle(.plain)
            if !store.searchText.isEmpty {
                Button {
                    store.searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color.white.opacity(0.065))
        .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .stroke(Color.white.opacity(0.08), lineWidth: 1)
        )
    }

    private var filter: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                SectionEyebrow(text: "Candidate archive", color: PerihelionPalette.violet)
                Text("\(store.filteredWorlds.count) of \(store.worlds.count) visible")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Toggle(isOn: $store.onlyPinned) {
                Image(systemName: "pin.fill")
            }
            .toggleStyle(.button)
            .tint(PerihelionPalette.violet)
            .help("Show only pinned targets")
        }
    }

    private var archiveStatus: some View {
        HStack(spacing: 10) {
            Image(systemName: "externaldrive.connected.to.line.below.fill")
                .foregroundStyle(PerihelionPalette.mint)
            VStack(alignment: .leading, spacing: 2) {
                Text("ARCHIVE SYNCHRONIZED")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                Text("Last packet · 14 seconds ago")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Circle()
                .fill(PerihelionPalette.mint)
                .frame(width: 6, height: 6)
        }
        .padding(12)
        .background(PerihelionPalette.mint.opacity(0.065))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

private struct CandidateRow: View {
    let world: CandidateWorld
    let isSelected: Bool
    let select: () -> Void
    let togglePin: () -> Void

    var body: some View {
        HStack(spacing: 11) {
            Button(action: select) {
                HStack(spacing: 11) {
                    ZStack {
                        Circle()
                            .fill(PerihelionPalette.worldColor(world).opacity(0.13))
                            .frame(width: 37, height: 37)
                        Image(systemName: world.classification.symbol)
                            .foregroundStyle(PerihelionPalette.worldColor(world))
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) {
                            Text(world.name)
                                .font(.system(size: 13, weight: .semibold, design: .rounded))
                            Text(world.confidenceLabel)
                                .font(.system(size: 9, weight: .bold, design: .monospaced))
                                .foregroundStyle(PerihelionPalette.mint)
                        }
                        Text("\(world.system) · \(world.distanceLabel)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button(action: togglePin) {
                Image(systemName: world.isPinned ? "pin.fill" : "pin")
                    .font(.caption)
                    .foregroundStyle(
                        world.isPinned ? PerihelionPalette.violet : Color.secondary
                    )
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
            .help(world.isPinned ? "Remove from queue" : "Add to queue")
        }
        .padding(10)
        .background(
            isSelected
                ? PerihelionPalette.cyan.opacity(0.105)
                : Color.white.opacity(0.025)
        )
        .clipShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 15, style: .continuous)
                .stroke(
                    isSelected
                        ? PerihelionPalette.cyan.opacity(0.28)
                        : Color.white.opacity(0.045),
                    lineWidth: 1
                )
        )
    }
}
