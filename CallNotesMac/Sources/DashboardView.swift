import CallNotesCore
import SwiftUI

struct DashboardView: View {
    @Bindable var model: AppModel
    @State private var selectedCallIDs: Set<UUID> = []
    @State private var drillDownTitle = "Calls"

    private var analytics: DashboardAnalytics { model.dashboardAnalytics }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header
                totals
                periodSection
                peopleSection
            }
            .padding(24)
        }
        .sheet(isPresented: Binding(
            get: { !selectedCallIDs.isEmpty },
            set: { if !$0 { selectedCallIDs = [] } }
        )) {
            DashboardDrillDownView(
                title: drillDownTitle,
                calls: analytics.calls.filter { selectedCallIDs.contains($0.id) }
            )
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Dashboard")
                .font(.largeTitle.weight(.semibold))
            Text("Your call activity, costs, and relationships at a glance.")
                .foregroundStyle(.secondary)
        }
    }

    private var totals: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: 12)], spacing: 12) {
            DashboardMetric(title: "Calls", value: "\(analytics.totals.callCount)", detail: "\(analytics.totals.localCallCount) local · \(analytics.totals.metaCallCount) Meta · \(analytics.totals.mixedCallCount) mixed")
            DashboardMetric(title: "Talk time", value: duration(analytics.totals.totalDurationSec), detail: talkTimeDetail)
            DashboardMetric(title: "Meta cost", value: currency(analytics.totals.metaCostDollars), detail: "\(duration(analytics.totals.metaBilledSeconds)) billed")
            DashboardMetric(title: "People", value: "\(analytics.contacts.count)", detail: "Known and unknown contacts")
        }
    }

    private var periodSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Activity over time")
                .font(.title3.weight(.semibold))
            ForEach(DashboardPeriodRange.allCases, id: \.self) { range in
                let periods = analytics.periods.filter { $0.range == range }
                if !periods.isEmpty {
                    let visible = Array(periods.prefix(Self.periodRowLimit))
                    VStack(alignment: .leading, spacing: 8) {
                        Text(range.rawValue.capitalized)
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.secondary)
                        ForEach(Array(visible.enumerated()), id: \.element.id) { index, period in
                            if index > 0 { Divider() }
                            Button {
                                show(period.callIDs, title: "\(range.rawValue.capitalized) of \(period.startsAt.formatted(date: .abbreviated, time: .omitted))")
                            } label: {
                                HStack {
                                    Text(period.startsAt.formatted(date: .abbreviated, time: .omitted))
                                    Spacer()
                                    VStack(alignment: .trailing, spacing: 3) {
                                        HStack(spacing: 10) {
                                            Text("\(period.callCount) calls")
                                            Text(duration(period.totalDurationSec))
                                                .frame(minWidth: 62, alignment: .trailing)
                                            Text(currency(period.metaCostDollars))
                                                .frame(minWidth: 62, alignment: .trailing)
                                                .foregroundStyle(period.metaBilledSeconds == 0 ? .secondary : CallNotesStyle.cloud)
                                        }
                                        Text("\(period.localCallCount) local · \(period.metaCallCount) Meta · \(period.mixedCallCount) mixed")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                .font(.subheadline)
                                .padding(.vertical, 8)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                        if periods.count > visible.count {
                            Divider()
                            Button {
                                show(
                                    periods.flatMap(\.callIDs),
                                    title: "Every \(range.rawValue) with activity"
                                )
                            } label: {
                                HStack {
                                    Text("Showing \(visible.count) of \(periods.count) \(range.rawValue)s")
                                    Spacer()
                                    Text("Show all calls")
                                }
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .padding(.vertical, 8)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(16)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
                }
            }
            if analytics.periods.isEmpty {
                ContentUnavailableView("No call activity yet", systemImage: "chart.bar")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 28)
            }
        }
    }

    private var peopleSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("People")
                .font(.title3.weight(.semibold))
            if analytics.contacts.isEmpty {
                Text("Contacts will appear here as calls are saved.")
                    .foregroundStyle(.secondary)
            } else {
                LazyVStack(spacing: 0) {
                    ForEach(Array(analytics.contacts.enumerated()), id: \.element.id) { index, contact in
                        if index > 0 { Divider() }
                        Button {
                            show(contact.callIDs, title: contact.name)
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(contact.name)
                                        .fontWeight(.medium)
                                    Text("Last contacted \(contact.lastContactedAt.formatted(date: .abbreviated, time: .omitted))")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Text("\(contact.callCount) calls")
                                Text("\(duration(contact.totalDurationSec)) total")
                                    .frame(minWidth: 95, alignment: .trailing)
                                Text("\(duration(contact.averageDurationSec)) avg")
                                    .frame(minWidth: 85, alignment: .trailing)
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.vertical, 10)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 6)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
            }
        }
    }

    private var talkTimeDetail: String {
        let incomplete = analytics.totals.incompleteCallCount
        guard incomplete > 0 else { return "Across all calls" }
        return "Across all calls · \(incomplete) still processing, not counted"
    }

    private static let periodRowLimit = 6

    private func show(_ ids: [UUID], title: String) {
        selectedCallIDs = Set(ids)
        drillDownTitle = title
    }

    private func duration(_ seconds: Int) -> String { DashboardFormat.duration(seconds) }
    private func currency(_ value: Double) -> String { DashboardFormat.currency(value) }
}

private enum DashboardFormat {
    static func duration(_ seconds: Int) -> String {
        let hours = seconds / 3_600
        let minutes = seconds % 3_600 / 60
        if hours > 0 { return "\(hours)h \(minutes)m" }
        return "\(minutes)m \(seconds % 60)s"
    }

    static func currency(_ value: Double) -> String {
        value.formatted(.currency(code: "USD").precision(.fractionLength(2...4)))
    }
}

private struct DashboardMetric: View {
    let title: String
    let value: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).foregroundStyle(.secondary)
            Text(value).font(.title2.weight(.semibold))
            Text(detail).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
    }
}

private struct DashboardDrillDownView: View {
    let title: String
    let calls: [DashboardCall]
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List(calls) { item in
                VStack(alignment: .leading, spacing: 4) {
                    Text(item.counterpartyName).fontWeight(.medium)
                    HStack {
                        Text(item.call.startedAt.formatted(date: .abbreviated, time: .shortened))
                        Text(item.isIncomplete ? "Incomplete" : duration(item.durationSec))
                        Text(item.engine.displayName)
                        if item.costDollars > 0 { Text(currency(item.costDollars)).foregroundStyle(CallNotesStyle.cloud) }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
            .navigationTitle(title)
            .toolbar { Button("Done") { dismiss() } }
        }
        .frame(minWidth: 460, minHeight: 360)
    }

    private func duration(_ seconds: Int) -> String { DashboardFormat.duration(seconds) }
    private func currency(_ value: Double) -> String { DashboardFormat.currency(value) }
}
