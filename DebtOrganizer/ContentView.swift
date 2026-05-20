import Charts
import SwiftUI

struct ContentView: View {
    @StateObject private var store = DebtStore()

    var body: some View {
        TabView {
            SummaryView()
                .tabItem { Label("总览", systemImage: "chart.pie.fill") }

            BillsView()
                .tabItem { Label("账单", systemImage: "list.bullet.rectangle.portrait.fill") }

            PlatformsView()
                .tabItem { Label("平台", systemImage: "creditcard.fill") }

            ArchiveView()
                .tabItem { Label("月度", systemImage: "calendar") }

            SettingsView()
                .tabItem { Label("设置", systemImage: "gearshape.fill") }
        }
        .environmentObject(store)
    }
}

private struct SummaryView: View {
    @EnvironmentObject private var store: DebtStore

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    pressureHeader
                    metricsGrid
                    platformSnapshot
                    upcomingSection
                }
                .padding()
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("负债总览")
        }
    }

    private var pressureHeader: some View {
        let metrics = store.metrics
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("净现金压力", systemImage: "waveform.path.ecg")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(metrics.cashPressure > 0 ? "需安排资金" : "现金覆盖")
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(metrics.cashPressure > 0 ? Color.red.opacity(0.12) : Color.green.opacity(0.12))
                    .foregroundStyle(metrics.cashPressure > 0 ? .red : .green)
                    .clipShape(Capsule())
            }

            Text(Formatters.currencyText(metrics.cashPressure))
                .font(.system(size: 38, weight: .bold, design: .rounded))
                .foregroundStyle(metrics.cashPressure > 0 ? .red : .green)

            Text("总负债 \(Formatters.currencyText(metrics.totalDebt))，可用现金 \(Formatters.currencyText(metrics.availableCash))")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .padding(18)
        .background(.background)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private var metricsGrid: some View {
        let metrics = store.metrics
        let columns = [GridItem(.flexible()), GridItem(.flexible())]

        return LazyVGrid(columns: columns, spacing: 12) {
            StatCard(title: "本月待还", value: Formatters.currencyText(metrics.monthlyDueTotal), icon: "calendar.badge.clock", tint: .indigo)
            StatCard(title: "未来 7 天", value: Formatters.currencyText(metrics.nextSevenDaysDue), icon: "bell.badge.fill", tint: .orange)
            StatCard(title: "已还金额", value: Formatters.currencyText(metrics.paidAmount), icon: "checkmark.circle.fill", tint: .green)
            StatCard(title: "未还金额", value: Formatters.currencyText(metrics.unpaidAmount), icon: "exclamationmark.circle.fill", tint: .red)
        }
    }

    private var platformSnapshot: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "平台负债概览", systemImage: "chart.bar.xaxis")

            Chart(store.platformSummaries) { summary in
                BarMark(
                    x: .value("剩余负债", summary.remainingDebt.doubleValue),
                    y: .value("平台", summary.platform)
                )
                .foregroundStyle(by: .value("平台", summary.platform))
            }
            .chartLegend(.hidden)
            .frame(height: 180)
        }
        .padding(16)
        .background(.background)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private var upcomingSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "近期待处理", systemImage: "clock.badge.exclamationmark")

            ForEach(store.upcomingBills()) { bill in
                BillCompactRow(bill: bill)
                if bill.id != store.upcomingBills().last?.id {
                    Divider()
                }
            }
        }
        .padding(16)
        .background(.background)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

private struct BillsView: View {
    @EnvironmentObject private var store: DebtStore
    @State private var searchText = ""
    @State private var filter: BillFilter = .all
    @State private var showingAddBill = false

    private var filteredBills: [DebtBill] {
        store.bills(matching: searchText, filter: filter)
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Picker("状态", selection: $filter) {
                        ForEach(BillFilter.allCases) { filter in
                            Text(filter.rawValue).tag(filter)
                        }
                    }
                    .pickerStyle(.segmented)
                }

                Section("账单明细") {
                    ForEach(filteredBills) { bill in
                        NavigationLink {
                            BillDetailView(bill: bill)
                        } label: {
                            BillRow(bill: bill)
                        }
                    }
                    .onDelete { offsets in
                        store.delete(offsets.map { filteredBills[$0] })
                    }
                }
            }
            .searchable(text: $searchText, prompt: "搜索平台、类型或备注")
            .navigationTitle("账单")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showingAddBill = true
                    } label: {
                        Label("新增账单", systemImage: "plus")
                    }
                }
            }
            .sheet(isPresented: $showingAddBill) {
                BillEditorView()
            }
        }
    }
}

private struct BillDetailView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var store: DebtStore
    @State private var draft: DebtBill
    @State private var amountText: String
    @State private var principalText: String
    @State private var feeText: String

    init(bill: DebtBill) {
        _draft = State(initialValue: bill)
        _amountText = State(initialValue: Formatters.decimalText(bill.amount))
        _principalText = State(initialValue: Formatters.decimalText(bill.principal))
        _feeText = State(initialValue: Formatters.decimalText(bill.fee))
    }

    var body: some View {
        Form {
            BillFormFields(
                bill: $draft,
                amountText: $amountText,
                principalText: $principalText,
                feeText: $feeText,
                platforms: store.platforms,
                billTypes: store.billTypes
            )
        }
        .navigationTitle(draft.platform)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("保存") {
                    draft.amount = Formatters.decimal(from: amountText)
                    draft.principal = Formatters.decimal(from: principalText)
                    draft.fee = Formatters.decimal(from: feeText)
                    store.update(draft)
                    dismiss()
                }
            }
        }
    }
}

private struct BillEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var store: DebtStore
    @State private var bill = DebtBill(
        platform: "花呗",
        billType: "消费",
        borrowDate: .now,
        amount: 0,
        principal: 0,
        fee: 0,
        dueDate: .now,
        status: .unpaid,
        autoDeduct: false,
        note: ""
    )
    @State private var amountText = ""
    @State private var principalText = ""
    @State private var feeText = ""

    var body: some View {
        NavigationStack {
            Form {
                BillFormFields(
                    bill: $bill,
                    amountText: $amountText,
                    principalText: $principalText,
                    feeText: $feeText,
                    platforms: store.platforms,
                    billTypes: store.billTypes
                )
            }
            .navigationTitle("新增账单")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        bill.amount = Formatters.decimal(from: amountText)
                        bill.principal = Formatters.decimal(from: principalText)
                        bill.fee = Formatters.decimal(from: feeText)
                        store.add(bill)
                        dismiss()
                    }
                }
            }
        }
    }
}

private struct BillFormFields: View {
    @Binding var bill: DebtBill
    @Binding var amountText: String
    @Binding var principalText: String
    @Binding var feeText: String
    let platforms: [String]
    let billTypes: [String]

    var body: some View {
        Section("基础信息") {
            Picker("平台", selection: $bill.platform) {
                ForEach(platforms, id: \.self) { Text($0).tag($0) }
            }
            Picker("账单类型", selection: $bill.billType) {
                ForEach(billTypes, id: \.self) { Text($0).tag($0) }
            }
            Picker("状态", selection: $bill.status) {
                ForEach(DebtStatus.allCases) { Text($0.rawValue).tag($0) }
            }
        }

        Section("金额") {
            TextField("应还金额", text: $amountText)
                .keyboardType(.decimalPad)
            TextField("本金", text: $principalText)
                .keyboardType(.decimalPad)
            TextField("利息/手续费", text: $feeText)
                .keyboardType(.decimalPad)
        }

        Section("日期与扣款") {
            DatePicker("消费/借款日期", selection: $bill.borrowDate, displayedComponents: .date)
            DatePicker("最晚还款日", selection: $bill.dueDate, displayedComponents: .date)
            Toggle("自动扣款", isOn: $bill.autoDeduct)
        }

        Section("备注") {
            TextField("备注", text: $bill.note, axis: .vertical)
                .lineLimit(2...4)
        }
    }
}

private struct PlatformsView: View {
    @EnvironmentObject private var store: DebtStore

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Chart(store.platformSummaries) { summary in
                        SectorMark(
                            angle: .value("剩余负债", max(summary.remainingDebt.doubleValue, 0)),
                            innerRadius: .ratio(0.62),
                            angularInset: 2
                        )
                        .foregroundStyle(by: .value("平台", summary.platform))
                    }
                    .frame(height: 230)
                }

                Section("平台账户") {
                    ForEach(store.platformSummaries) { summary in
                        PlatformSummaryRow(summary: summary)
                    }
                }
            }
            .navigationTitle("平台")
        }
    }
}

private struct ArchiveView: View {
    @EnvironmentObject private var store: DebtStore

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Chart(store.archiveRows.reversed()) { archive in
                        BarMark(
                            x: .value("月份", Formatters.month.string(from: archive.month)),
                            y: .value("应还总额", archive.dueTotal.doubleValue)
                        )
                        .foregroundStyle(.indigo)

                        LineMark(
                            x: .value("月份", Formatters.month.string(from: archive.month)),
                            y: .value("期末负债", archive.endingDebt.doubleValue)
                        )
                        .foregroundStyle(.red)
                    }
                    .frame(height: 220)
                }

                Section("月度归档") {
                    ForEach(store.archiveRows) { archive in
                        ArchiveRow(archive: archive)
                    }
                }
            }
            .navigationTitle("月度")
        }
    }
}

private struct SettingsView: View {
    @EnvironmentObject private var store: DebtStore
    @State private var cashText = ""
    @State private var showingReset = false

    var body: some View {
        NavigationStack {
            List {
                Section("现金设置") {
                    TextField("可用现金", text: $cashText)
                        .keyboardType(.decimalPad)
                    Button {
                        store.updateAvailableCash(Formatters.decimal(from: cashText))
                    } label: {
                        Label("保存现金余额", systemImage: "checkmark.circle")
                    }
                }

                Section("平台名称") {
                    ForEach(store.platforms, id: \.self) { platform in
                        Text(platform)
                    }
                }

                Section("状态枚举") {
                    ForEach(DebtStatus.allCases) { status in
                        Label(status.rawValue, systemImage: "circle.fill")
                            .foregroundStyle(status.color)
                    }
                }

                Section("原始数据") {
                    Button(role: .destructive) {
                        showingReset = true
                    } label: {
                        Label("恢复 Excel 示例数据", systemImage: "arrow.counterclockwise")
                    }
                }
            }
            .navigationTitle("设置")
            .onAppear {
                cashText = Formatters.decimalText(store.availableCash)
            }
            .confirmationDialog("恢复后会覆盖当前本机记录。", isPresented: $showingReset, titleVisibility: .visible) {
                Button("恢复示例数据", role: .destructive) {
                    store.resetToSeedData()
                    cashText = Formatters.decimalText(store.availableCash)
                }
            }
        }
    }
}

private struct StatCard: View {
    let title: String
    let value: String
    let icon: String
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(systemName: icon)
                .foregroundStyle(tint)
                .font(.title3)

            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)

            Text(value)
                .font(.headline.monospacedDigit())
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(.background)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

private struct SectionHeader: View {
    let title: String
    let systemImage: String

    var body: some View {
        Label(title, systemImage: systemImage)
            .font(.headline)
    }
}

private struct StatusBadge: View {
    let status: DebtStatus

    var body: some View {
        Text(status.rawValue)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(status.color.opacity(0.13))
            .foregroundStyle(status.color)
            .clipShape(Capsule())
    }
}

private struct BillCompactRow: View {
    let bill: DebtBill

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("\(bill.platform) · \(bill.billType)")
                    .font(.subheadline.weight(.semibold))
                Text("最晚 \(Formatters.date.string(from: bill.dueDate))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 4) {
                Text(Formatters.currencyText(bill.amount))
                    .font(.subheadline.weight(.bold).monospacedDigit())
                StatusBadge(status: bill.status)
            }
        }
    }
}

private struct BillRow: View {
    let bill: DebtBill

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(bill.platform)
                        .font(.headline)
                    Text(bill.billType)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                VStack(alignment: .trailing, spacing: 4) {
                    Text(Formatters.currencyText(bill.amount))
                        .font(.headline.monospacedDigit())
                    StatusBadge(status: bill.status)
                }
            }

            HStack {
                Label(Formatters.date.string(from: bill.dueDate), systemImage: "calendar")
                if bill.autoDeduct {
                    Label("自动扣款", systemImage: "bolt.fill")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            if !bill.note.isEmpty {
                Text(bill.note)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 4)
    }
}

private struct PlatformSummaryRow: View {
    let summary: PlatformSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(summary.platform)
                    .font(.headline)
                Spacer()
                Text(Formatters.currencyText(summary.remainingDebt))
                    .font(.headline.monospacedDigit())
            }

            HStack {
                Label("本月 \(Formatters.currencyText(summary.monthlyDue))", systemImage: "calendar")
                Spacer()
                if let nextDue = summary.nextDueDate {
                    Label(Formatters.date.string(from: nextDue), systemImage: "clock")
                } else {
                    Label("暂无待还", systemImage: "checkmark.circle")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            HStack {
                Label(summary.autoDeduct ? "有自动扣款" : "无自动扣款", systemImage: summary.autoDeduct ? "bolt.fill" : "bolt.slash")
                    .font(.caption)
                    .foregroundStyle(summary.autoDeduct ? .orange : .secondary)
            }
        }
        .padding(.vertical, 4)
    }
}

private struct ArchiveRow: View {
    let archive: MonthlyArchive

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(Formatters.month.string(from: archive.month))
                    .font(.headline)
                Spacer()
                Text(Formatters.currencyText(archive.endingDebt))
                    .font(.headline.monospacedDigit())
            }

            Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 8) {
                GridRow {
                    Text("应还")
                    Text("实还")
                    Text("逾期")
                }
                .font(.caption)
                .foregroundStyle(.secondary)

                GridRow {
                    Text(Formatters.currencyText(archive.dueTotal))
                    Text(Formatters.currencyText(archive.paidTotal))
                    Text("\(archive.overdueCount) 次")
                }
                .font(.subheadline.monospacedDigit())
            }
        }
        .padding(.vertical, 4)
    }
}

#Preview {
    ContentView()
}
