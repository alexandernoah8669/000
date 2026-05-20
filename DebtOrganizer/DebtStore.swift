import Foundation

final class DebtStore: ObservableObject {
    @Published private(set) var bills: [DebtBill]
    @Published private(set) var archives: [MonthlyArchive]
    @Published private(set) var availableCash: Decimal

    private let storageKey = "DebtOrganizer.AppData.v1"
    private let calendar = Calendar.current

    init() {
        if let data = UserDefaults.standard.data(forKey: storageKey),
           let decoded = try? JSONDecoder().decode(AppData.self, from: data) {
            bills = decoded.bills
            archives = decoded.archives
            availableCash = decoded.availableCash
        } else {
            let seed = SeedData.appData
            bills = seed.bills
            archives = seed.archives
            availableCash = seed.availableCash
        }
    }

    var platforms: [String] {
        Array(Set(bills.map(\.platform)).union(SeedData.platforms)).sorted()
    }

    var billTypes: [String] {
        Array(Set(bills.map(\.billType)).union(SeedData.billTypes)).sorted()
    }

    var metrics: DebtMetrics {
        let month = currentMonthInterval()
        let today = calendar.startOfDay(for: .now)
        let sevenDays = calendar.date(byAdding: .day, value: 7, to: today) ?? today

        let monthlyDue = bills
            .filter { $0.dueDate >= month.start && $0.dueDate < month.end }
            .sum(\.amount)

        let nextSevenDays = bills
            .filter { $0.status != .paid && $0.dueDate >= today && $0.dueDate <= sevenDays }
            .sum(\.amount)

        let paid = bills.filter { $0.status == .paid }.sum(\.amount)
        let unpaid = bills.filter { $0.status != .paid }.sum(\.amount)
        let pressure = unpaid - availableCash

        return DebtMetrics(
            monthlyDueTotal: monthlyDue,
            nextSevenDaysDue: nextSevenDays,
            paidAmount: paid,
            unpaidAmount: unpaid,
            totalDebt: unpaid,
            availableCash: availableCash,
            cashPressure: pressure
        )
    }

    var platformSummaries: [PlatformSummary] {
        let month = currentMonthInterval()

        return platforms.map { platform in
            let related = bills.filter { $0.platform == platform }
            let active = related.filter { $0.status != .paid }
            let remainingDebt = active.sum(\.amount)
            let monthlyDue = related
                .filter { $0.dueDate >= month.start && $0.dueDate < month.end }
                .sum(\.amount)
            let nextDue = active
                .filter { $0.dueDate >= calendar.startOfDay(for: .now) }
                .map(\.dueDate)
                .min()
            let hasAutoDeduct = related.contains { $0.autoDeduct }

            return PlatformSummary(
                platform: platform,
                remainingDebt: remainingDebt,
                monthlyDue: monthlyDue,
                nextDueDate: nextDue,
                autoDeduct: hasAutoDeduct
            )
        }
        .sorted { $0.remainingDebt > $1.remainingDebt }
    }

    var currentMonthArchive: MonthlyArchive {
        let month = currentMonthInterval()
        let monthBills = bills.filter { $0.dueDate >= month.start && $0.dueDate < month.end }
        let newDebt = bills
            .filter { $0.borrowDate >= month.start && $0.borrowDate < month.end }
            .sum(\.principal)

        return MonthlyArchive(
            month: month.start,
            dueTotal: monthBills.sum(\.amount),
            paidTotal: monthBills.filter { $0.status == .paid }.sum(\.amount),
            overdueCount: monthBills.filter { $0.status == .overdue }.count,
            newDebt: newDebt,
            endingDebt: metrics.totalDebt
        )
    }

    var archiveRows: [MonthlyArchive] {
        [currentMonthArchive] + archives.filter {
            !calendar.isDate($0.month, equalTo: currentMonthArchive.month, toGranularity: .month)
        }
    }

    func bills(matching query: String, filter: BillFilter) -> [DebtBill] {
        bills
            .filter { bill in
                guard let status = filter.status else { return true }
                return bill.status == status
            }
            .filter { bill in
                let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { return true }
                return bill.platform.localizedCaseInsensitiveContains(trimmed)
                    || bill.billType.localizedCaseInsensitiveContains(trimmed)
                    || bill.note.localizedCaseInsensitiveContains(trimmed)
            }
            .sorted { lhs, rhs in
                if lhs.status == .paid && rhs.status != .paid {
                    return false
                }
                if lhs.status != .paid && rhs.status == .paid {
                    return true
                }
                return lhs.dueDate < rhs.dueDate
            }
    }

    func upcomingBills(limit: Int = 5) -> [DebtBill] {
        bills
            .filter { $0.status != .paid }
            .sorted { $0.dueDate < $1.dueDate }
            .prefix(limit)
            .map { $0 }
    }

    func add(_ bill: DebtBill) {
        bills.append(bill)
        save()
    }

    func update(_ bill: DebtBill) {
        guard let index = bills.firstIndex(where: { $0.id == bill.id }) else { return }
        bills[index] = bill
        save()
    }

    func delete(_ billsToDelete: [DebtBill]) {
        let ids = Set(billsToDelete.map(\.id))
        bills.removeAll { ids.contains($0.id) }
        save()
    }

    func updateAvailableCash(_ cash: Decimal) {
        availableCash = cash
        save()
    }

    func resetToSeedData() {
        let seed = SeedData.appData
        bills = seed.bills
        archives = seed.archives
        availableCash = seed.availableCash
        save()
    }

    private func save() {
        let data = AppData(bills: bills, archives: archives, availableCash: availableCash)
        if let encoded = try? JSONEncoder().encode(data) {
            UserDefaults.standard.set(encoded, forKey: storageKey)
        }
    }

    private func currentMonthInterval() -> (start: Date, end: Date) {
        let start = calendar.date(from: calendar.dateComponents([.year, .month], from: .now)) ?? .now
        let end = calendar.date(byAdding: .month, value: 1, to: start) ?? start
        return (start, end)
    }
}

private extension Array where Element == DebtBill {
    func sum(_ keyPath: KeyPath<DebtBill, Decimal>) -> Decimal {
        reduce(0) { $0 + $1[keyPath: keyPath] }
    }
}

private extension Array where Element == MonthlyArchive {
    func sum(_ keyPath: KeyPath<MonthlyArchive, Decimal>) -> Decimal {
        reduce(0) { $0 + $1[keyPath: keyPath] }
    }
}

enum SeedData {
    static let platforms = ["花呗", "京东金条", "京东白条", "抖音放心借"]
    static let billTypes = ["消费", "消费分期", "借款", "白条消费", "现金借款"]

    static let appData = AppData(
        bills: [
            DebtBill(
                platform: "花呗",
                billType: "消费分期",
                borrowDate: .appDate(2026, 4, 22),
                amount: 1280,
                principal: 1220,
                fee: 60,
                dueDate: .appDate(2026, 5, 19),
                status: .unpaid,
                autoDeduct: true,
                note: "手机分期第 2 期"
            ),
            DebtBill(
                platform: "京东金条",
                billType: "借款",
                borrowDate: .appDate(2026, 4, 7),
                amount: 2350,
                principal: 2200,
                fee: 150,
                dueDate: .appDate(2026, 5, 23),
                status: .unpaid,
                autoDeduct: false,
                note: "短期周转"
            ),
            DebtBill(
                platform: "京东白条",
                billType: "白条消费",
                borrowDate: .appDate(2026, 4, 27),
                amount: 890,
                principal: 860,
                fee: 30,
                dueDate: .appDate(2026, 5, 15),
                status: .overdue,
                autoDeduct: true,
                note: "家电账单，需尽快处理"
            ),
            DebtBill(
                platform: "抖音放心借",
                billType: "现金借款",
                borrowDate: .appDate(2026, 3, 18),
                amount: 1600,
                principal: 1500,
                fee: 100,
                dueDate: .appDate(2026, 5, 29),
                status: .partial,
                autoDeduct: false,
                note: "已还 500，剩余待跟进"
            ),
            DebtBill(
                platform: "花呗",
                billType: "消费",
                borrowDate: .appDate(2026, 4, 2),
                amount: 620,
                principal: 620,
                fee: 0,
                dueDate: .appDate(2026, 5, 7),
                status: .paid,
                autoDeduct: true,
                note: "上月餐饮消费"
            ),
            DebtBill(
                platform: "京东白条",
                billType: "消费分期",
                borrowDate: .appDate(2026, 5, 7),
                amount: 450,
                principal: 430,
                fee: 20,
                dueDate: .appDate(2026, 6, 6),
                status: .unpaid,
                autoDeduct: true,
                note: "日用品分期"
            ),
            DebtBill(
                platform: "抖音放心借",
                billType: "借款",
                borrowDate: .appDate(2026, 4, 12),
                amount: 980,
                principal: 930,
                fee: 50,
                dueDate: .appDate(2026, 5, 12),
                status: .paid,
                autoDeduct: false,
                note: "已结清"
            ),
            DebtBill(
                platform: "京东金条",
                billType: "借款",
                borrowDate: .appDate(2026, 5, 12),
                amount: 3200,
                principal: 3000,
                fee: 200,
                dueDate: .appDate(2026, 6, 11),
                status: .unpaid,
                autoDeduct: false,
                note: "备用金"
            )
        ],
        archives: [
            MonthlyArchive(
                month: .appDate(2026, 4, 1),
                dueTotal: 4860,
                paidTotal: 4860,
                overdueCount: 0,
                newDebt: 1200,
                endingDebt: 8200
            ),
            MonthlyArchive(
                month: .appDate(2026, 3, 1),
                dueTotal: 5120,
                paidTotal: 4700,
                overdueCount: 1,
                newDebt: 1800,
                endingDebt: 9100
            ),
            MonthlyArchive(
                month: .appDate(2026, 2, 1),
                dueTotal: 3980,
                paidTotal: 3980,
                overdueCount: 0,
                newDebt: 900,
                endingDebt: 7600
            )
        ],
        availableCash: 5000
    )
}
