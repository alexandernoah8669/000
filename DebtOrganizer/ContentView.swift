import Charts
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @StateObject private var store = DebtStore()

    var body: some View {
        TabView {
            PortfolioOverviewView()
                .tabItem { Label("总览", systemImage: "chart.pie.fill") }

            AssetsView()
                .tabItem { Label("资产", systemImage: "tray.full.fill") }

            DebtWorkspaceView()
                .tabItem { Label("负债", systemImage: "creditcard.fill") }
        }
        .environmentObject(store)
    }
}

private struct PortfolioOverviewView: View {
    @EnvironmentObject private var store: DebtStore

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    netWorthHeader
                    portfolioMetricsGrid
                    assetMixCard
                    debtFocusCard
                }
                .padding()
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("总览")
        }
    }

    private var netWorthHeader: some View {
        let metrics = store.portfolioMetrics
        let isPositive = metrics.netWorth >= 0

        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("净资产", systemImage: "chart.pie.fill")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(isPositive ? "资产覆盖" : "资不抵债")
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(isPositive ? Color.green.opacity(0.12) : Color.red.opacity(0.12))
                    .foregroundStyle(isPositive ? .green : .red)
                    .clipShape(Capsule())
            }

            Text(Formatters.currencyText(metrics.netWorth))
                .font(.system(size: 38, weight: .bold, design: .rounded))
                .foregroundStyle(isPositive ? Color.primary : Color.red)
                .minimumScaleFactor(0.72)
                .lineLimit(1)

            Text("总资产 \(Formatters.currencyText(metrics.totalAssets))，总负债 \(Formatters.currencyText(metrics.totalDebt))")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .padding(18)
        .background(.background)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private var portfolioMetricsGrid: some View {
        let metrics = store.portfolioMetrics
        let columns = [GridItem(.flexible()), GridItem(.flexible())]

        return LazyVGrid(columns: columns, spacing: 12) {
            StatCard(title: "总资产", value: Formatters.currencyText(metrics.totalAssets), icon: "tray.full.fill", tint: .green)
            StatCard(title: "总负债", value: Formatters.currencyText(metrics.totalDebt), icon: "creditcard.fill", tint: .red)
            StatCard(title: "现金类资产", value: Formatters.currencyText(metrics.cashAssets), icon: "banknote.fill", tint: .green)
            StatCard(title: "负债率", value: Formatters.percentText(metrics.debtToAssetRatio), icon: "percent", tint: .orange)
        }
    }

    private var assetMixCard: some View {
        let summaries = store.assetCategorySummaries
        let metrics = store.portfolioMetrics

        return VStack(alignment: .leading, spacing: 14) {
            SectionHeader(title: "资产结构", systemImage: "square.grid.2x2.fill")

            if metrics.totalAssets > 0 {
                Chart(summaries) { summary in
                    SectorMark(
                        angle: .value("资产", max(summary.total.doubleValue, 0)),
                        innerRadius: .ratio(0.58),
                        angularInset: 2
                    )
                    .foregroundStyle(by: .value("分类", summary.category.shortTitle))
                }
                .chartLegend(position: .bottom)
                .frame(height: 220)
            }

            VStack(spacing: 10) {
                ForEach(summaries) { summary in
                    AssetCategorySummaryRow(summary: summary, totalAssets: metrics.totalAssets)
                    if summary.id != summaries.last?.id {
                        Divider()
                    }
                }
            }
        }
        .padding(16)
        .background(.background)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private var debtFocusCard: some View {
        let metrics = store.metrics
        let upcoming = store.upcomingBills(limit: 4)

        return VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "负债压力", systemImage: "waveform.path.ecg")

            HStack(spacing: 12) {
                MiniMetric(title: "本月待还", value: Formatters.currencyText(metrics.monthlyDueTotal), tint: .indigo)
                MiniMetric(title: "未来 7 天", value: Formatters.currencyText(metrics.nextSevenDaysDue), tint: .orange)
            }

            if !upcoming.isEmpty {
                Divider()
                ForEach(upcoming) { bill in
                    BillCompactRow(bill: bill)
                    if bill.id != upcoming.last?.id {
                        Divider()
                    }
                }
            }
        }
        .padding(16)
        .background(.background)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

private struct AssetsView: View {
    @EnvironmentObject private var store: DebtStore
    @State private var searchText = ""
    @State private var filter: AssetFilter = .all
    @State private var showingAddAsset = false

    private var filteredAssets: [AssetItem] {
        store.assets(matching: searchText, filter: filter)
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    assetSnapshot
                }

                Section {
                    Picker("分类", selection: $filter) {
                        ForEach(AssetFilter.allCases) { filter in
                            Text(filter.rawValue).tag(filter)
                        }
                    }
                    .pickerStyle(.segmented)
                }

                Section("资产明细") {
                    ForEach(filteredAssets) { asset in
                        NavigationLink {
                            AssetDetailView(asset: asset)
                        } label: {
                            AssetRow(asset: asset)
                        }
                    }
                    .onDelete { offsets in
                        store.delete(offsets.map { filteredAssets[$0] })
                    }
                }
            }
            .searchable(text: $searchText, prompt: "搜索资产名称、分类或备注")
            .navigationTitle("资产")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showingAddAsset = true
                    } label: {
                        Label("新增资产", systemImage: "plus")
                    }
                }
            }
            .sheet(isPresented: $showingAddAsset) {
                AssetEditorView()
            }
        }
    }

    private var assetSnapshot: some View {
        let metrics = store.portfolioMetrics

        return VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("资产总额")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(Formatters.currencyText(metrics.totalAssets))
                        .font(.title2.weight(.bold).monospacedDigit())
                }

                Spacer()

                VStack(alignment: .trailing, spacing: 4) {
                    Text("净资产")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(Formatters.currencyText(metrics.netWorth))
                        .font(.headline.monospacedDigit())
                        .foregroundStyle(metrics.netWorth >= 0 ? .green : .red)
                }
            }

            Chart(store.assetCategorySummaries) { summary in
                BarMark(
                    x: .value("金额", summary.total.doubleValue),
                    y: .value("分类", summary.category.shortTitle)
                )
                .foregroundStyle(by: .value("分类", summary.category.shortTitle))
            }
            .chartLegend(.hidden)
            .frame(height: 150)
        }
        .padding(.vertical, 6)
    }
}

private struct AssetDetailView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var store: DebtStore
    @State private var draft: AssetItem
    @State private var amountText: String

    init(asset: AssetItem) {
        _draft = State(initialValue: asset)
        _amountText = State(initialValue: Formatters.decimalText(asset.amount))
    }

    var body: some View {
        Form {
            AssetFormFields(asset: $draft, amountText: $amountText)
        }
        .navigationTitle(draft.name.isEmpty ? "资产明细" : draft.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("保存") {
                    draft.amount = Formatters.decimal(from: amountText)
                    store.update(draft)
                    dismiss()
                }
            }
        }
    }
}

private struct AssetEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var store: DebtStore
    @State private var asset = AssetItem(
        name: "",
        category: .cash,
        amount: 0,
        updatedAt: .now,
        note: ""
    )
    @State private var amountText = ""

    var body: some View {
        NavigationStack {
            Form {
                AssetFormFields(asset: $asset, amountText: $amountText)
            }
            .navigationTitle("新增资产")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        asset.amount = Formatters.decimal(from: amountText)
                        store.add(asset)
                        dismiss()
                    }
                    .disabled(asset.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }
}

private struct AssetFormFields: View {
    @Binding var asset: AssetItem
    @Binding var amountText: String

    var body: some View {
        Section("基础信息") {
            TextField("资产名称", text: $asset.name)
            Picker("资产分类", selection: $asset.category) {
                ForEach(AssetCategory.allCases) { category in
                    Label(category.rawValue, systemImage: category.systemImage).tag(category)
                }
            }
        }

        Section("估值") {
            TextField("当前金额", text: $amountText)
                .keyboardType(.decimalPad)
            DatePicker("更新日期", selection: $asset.updatedAt, displayedComponents: .date)
        }

        Section("备注") {
            TextField("备注", text: $asset.note, axis: .vertical)
                .lineLimit(2...4)
        }
    }
}

private struct DebtWorkspaceView: View {
    @EnvironmentObject private var store: DebtStore

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    debtHeader
                    debtMetricsGrid
                    debtModules
                    upcomingSection
                }
                .padding()
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("负债")
        }
    }

    private var debtHeader: some View {
        let metrics = store.metrics
        let needsCash = metrics.cashPressure > 0

        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("净现金压力", systemImage: "waveform.path.ecg")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(needsCash ? "需安排资金" : "现金覆盖")
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(needsCash ? Color.red.opacity(0.12) : Color.green.opacity(0.12))
                    .foregroundStyle(needsCash ? .red : .green)
                    .clipShape(Capsule())
            }

            Text(Formatters.currencyText(metrics.cashPressure))
                .font(.system(size: 36, weight: .bold, design: .rounded))
                .foregroundStyle(needsCash ? .red : .green)
                .minimumScaleFactor(0.72)
                .lineLimit(1)

            Text("总负债 \(Formatters.currencyText(metrics.totalDebt))，现金类资产 \(Formatters.currencyText(metrics.availableCash))")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .padding(18)
        .background(.background)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private var debtMetricsGrid: some View {
        let metrics = store.metrics
        let columns = [GridItem(.flexible()), GridItem(.flexible())]

        return LazyVGrid(columns: columns, spacing: 12) {
            StatCard(title: "本月待还", value: Formatters.currencyText(metrics.monthlyDueTotal), icon: "calendar.badge.clock", tint: .indigo)
            StatCard(title: "未来 7 天", value: Formatters.currencyText(metrics.nextSevenDaysDue), icon: "bell.badge.fill", tint: .orange)
            StatCard(title: "已还金额", value: Formatters.currencyText(metrics.paidAmount), icon: "checkmark.circle.fill", tint: .green)
            StatCard(title: "未还金额", value: Formatters.currencyText(metrics.unpaidAmount), icon: "exclamationmark.circle.fill", tint: .red)
        }
    }

    private var debtModules: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "负债系统", systemImage: "square.grid.2x2")

            NavigationLink {
                BillsView()
            } label: {
                ModuleLinkRow(title: "账单明细", subtitle: "搜索、筛选、新增、编辑和导入账单", systemImage: "list.bullet.rectangle.portrait.fill", tint: .indigo)
            }
            .buttonStyle(.plain)

            NavigationLink {
                PlatformsView()
            } label: {
                ModuleLinkRow(title: "平台账户", subtitle: "按平台汇总剩余负债和下次还款日", systemImage: "creditcard.fill", tint: .orange)
            }
            .buttonStyle(.plain)

            NavigationLink {
                ArchiveView()
            } label: {
                ModuleLinkRow(title: "月度归档", subtitle: "查看应还、实还、逾期和期末负债", systemImage: "calendar", tint: .blue)
            }
            .buttonStyle(.plain)

            NavigationLink {
                SettingsView()
            } label: {
                ModuleLinkRow(title: "负债设置", subtitle: "状态枚举、平台名称和示例数据", systemImage: "gearshape.fill", tint: .secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(16)
        .background(.background)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private var upcomingSection: some View {
        let upcoming = store.upcomingBills()

        return VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "近期待处理", systemImage: "clock.badge.exclamationmark")

            ForEach(upcoming) { bill in
                BillCompactRow(bill: bill)
                if bill.id != upcoming.last?.id {
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
    @State private var showingTemplateExporter = false
    @State private var showingImporter = false
    @State private var importAlert: ImportAlert?

    private var filteredBills: [DebtBill] {
        store.bills(matching: searchText, filter: filter)
    }

    var body: some View {
        List {
            Section {
                Button {
                    showingTemplateExporter = true
                } label: {
                    Label("下载 Excel 导入模板", systemImage: "square.and.arrow.down")
                }

                Button {
                    showingImporter = true
                } label: {
                    Label("导入填写好的模板", systemImage: "tablecells.badge.ellipsis")
                }
            } header: {
                Text("批量导入")
            } footer: {
                Text("先下载模板并按表头填写，保存后从这里选择 .xlsx 文件回导。")
            }

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
        .fileExporter(
            isPresented: $showingTemplateExporter,
            document: BillImportTemplateDocument(),
            contentType: .xlsxWorkbook,
            defaultFilename: "账单导入模板.xlsx"
        ) { result in
            handleTemplateExport(result)
        }
        .fileImporter(
            isPresented: $showingImporter,
            allowedContentTypes: BillImporter.supportedContentTypes,
            allowsMultipleSelection: false
        ) { result in
            handleImport(result)
        }
        .alert(item: $importAlert) { alert in
            Alert(
                title: Text(alert.title),
                message: Text(alert.message),
                dismissButton: .default(Text("知道了"))
            )
        }
    }

    private func handleTemplateExport(_ result: Result<URL, Error>) {
        switch result {
        case .success:
            importAlert = ImportAlert(title: "模板已导出", message: "填写第一张工作表后，可从“导入填写好的模板”回导。")
        case .failure(let error):
            if error is CancellationError { return }
            importAlert = ImportAlert(title: "导出失败", message: error.localizedDescription)
        }
    }

    private func handleImport(_ result: Result<[URL], Error>) {
        do {
            guard let url = try result.get().first else { return }
            let importResult = try store.importBills(from: url)
            importAlert = ImportAlert(title: "导入完成", message: importResult.message)
        } catch {
            importAlert = ImportAlert(title: "导入失败", message: error.localizedDescription)
        }
    }
}

private struct ImportAlert: Identifiable {
    let id = UUID()
    let title: String
    let message: String
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

private struct ArchiveView: View {
    @EnvironmentObject private var store: DebtStore

    var body: some View {
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

private struct SettingsView: View {
    @EnvironmentObject private var store: DebtStore
    @State private var showingReset = false

    var body: some View {
        List {
            Section("现金覆盖") {
                LabeledContent("现金类资产", value: Formatters.currencyText(store.availableCash))
                Text("现金余额在资产页维护，负债现金压力会自动引用现金类资产合计。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
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
                    Label("恢复资产负债示例数据", systemImage: "arrow.counterclockwise")
                }
            }
        }
        .navigationTitle("负债设置")
        .confirmationDialog("恢复后会覆盖当前本机记录。", isPresented: $showingReset, titleVisibility: .visible) {
            Button("恢复示例数据", role: .destructive) {
                store.resetToSeedData()
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
                .minimumScaleFactor(0.72)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(.background)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

private struct MiniMetric: View {
    let title: String
    let value: String
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.headline.monospacedDigit())
                .foregroundStyle(tint)
                .minimumScaleFactor(0.72)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(tint.opacity(0.08))
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

private struct ModuleLinkRow: View {
    let title: String
    let subtitle: String
    let systemImage: String
    let tint: Color

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.title3)
                .foregroundStyle(tint)
                .frame(width: 34, height: 34)
                .background(tint.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Spacer()
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 6)
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

private struct AssetCategoryBadge: View {
    let category: AssetCategory

    var body: some View {
        Label(category.shortTitle, systemImage: category.systemImage)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(category.color.opacity(0.12))
            .foregroundStyle(category.color)
            .clipShape(Capsule())
    }
}

private struct AssetCategorySummaryRow: View {
    let summary: AssetCategorySummary
    let totalAssets: Decimal

    private var shareText: String {
        guard totalAssets.doubleValue > 0 else { return "0%" }
        return Formatters.percentText(summary.total.doubleValue / totalAssets.doubleValue)
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: summary.category.systemImage)
                .foregroundStyle(summary.category.color)
                .frame(width: 30)

            VStack(alignment: .leading, spacing: 3) {
                Text(summary.category.rawValue)
                    .font(.subheadline.weight(.semibold))
                Text("\(summary.count) 项 · 占比 \(shareText)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Text(Formatters.currencyText(summary.total))
                .font(.subheadline.weight(.bold).monospacedDigit())
                .minimumScaleFactor(0.72)
                .lineLimit(1)
        }
    }
}

private struct AssetRow: View {
    let asset: AssetItem

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(asset.name)
                        .font(.headline)
                    Text("更新于 \(Formatters.date.string(from: asset.updatedAt))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                VStack(alignment: .trailing, spacing: 5) {
                    Text(Formatters.currencyText(asset.amount))
                        .font(.headline.monospacedDigit())
                    AssetCategoryBadge(category: asset.category)
                }
            }

            if !asset.note.isEmpty {
                Text(asset.note)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 4)
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
