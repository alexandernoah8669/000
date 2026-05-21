import Foundation
import SwiftUI

enum DebtStatus: String, CaseIterable, Codable, Identifiable {
    case unpaid = "未还"
    case paid = "已还"
    case overdue = "逾期"
    case partial = "部分还款"

    var id: String { rawValue }

    var color: Color {
        switch self {
        case .unpaid:
            return .orange
        case .paid:
            return .green
        case .overdue:
            return .red
        case .partial:
            return .blue
        }
    }
}

enum BillFilter: String, CaseIterable, Identifiable {
    case all = "全部"
    case unpaid = "未还"
    case paid = "已还"
    case overdue = "逾期"
    case partial = "部分还款"

    var id: String { rawValue }

    var status: DebtStatus? {
        switch self {
        case .all:
            return nil
        case .unpaid:
            return .unpaid
        case .paid:
            return .paid
        case .overdue:
            return .overdue
        case .partial:
            return .partial
        }
    }
}

enum AssetCategory: String, CaseIterable, Codable, Identifiable {
    case cash = "现金类资产"
    case investment = "投资类资产"
    case physical = "实物资产"

    var id: String { rawValue }

    var shortTitle: String {
        switch self {
        case .cash:
            return "现金"
        case .investment:
            return "投资"
        case .physical:
            return "实物"
        }
    }

    var systemImage: String {
        switch self {
        case .cash:
            return "banknote.fill"
        case .investment:
            return "chart.line.uptrend.xyaxis"
        case .physical:
            return "shippingbox.fill"
        }
    }

    var color: Color {
        switch self {
        case .cash:
            return .green
        case .investment:
            return .indigo
        case .physical:
            return .orange
        }
    }
}

enum AssetFilter: String, CaseIterable, Identifiable {
    case all = "全部"
    case cash = "现金"
    case investment = "投资"
    case physical = "实物"

    var id: String { rawValue }

    var category: AssetCategory? {
        switch self {
        case .all:
            return nil
        case .cash:
            return .cash
        case .investment:
            return .investment
        case .physical:
            return .physical
        }
    }
}

struct AssetItem: Identifiable, Codable, Equatable {
    var id: UUID = UUID()
    var name: String
    var category: AssetCategory
    var amount: Decimal
    var updatedAt: Date
    var note: String
}

struct DebtBill: Identifiable, Codable, Equatable {
    var id: UUID = UUID()
    var platform: String
    var billType: String
    var borrowDate: Date
    var amount: Decimal
    var principal: Decimal
    var fee: Decimal
    var dueDate: Date
    var status: DebtStatus
    var autoDeduct: Bool
    var note: String
}

struct MonthlyArchive: Identifiable, Codable, Equatable {
    var id: UUID = UUID()
    var month: Date
    var dueTotal: Decimal
    var paidTotal: Decimal
    var overdueCount: Int
    var newDebt: Decimal
    var endingDebt: Decimal
}

struct PlatformSummary: Identifiable, Equatable {
    var id: String { platform }
    var platform: String
    var remainingDebt: Decimal
    var monthlyDue: Decimal
    var nextDueDate: Date?
    var autoDeduct: Bool
}

struct AssetCategorySummary: Identifiable, Equatable {
    var id: AssetCategory { category }
    var category: AssetCategory
    var total: Decimal
    var count: Int
}

struct DebtMetrics: Equatable {
    var monthlyDueTotal: Decimal
    var nextSevenDaysDue: Decimal
    var paidAmount: Decimal
    var unpaidAmount: Decimal
    var totalDebt: Decimal
    var availableCash: Decimal
    var cashPressure: Decimal
}

struct PortfolioMetrics: Equatable {
    var totalAssets: Decimal
    var totalDebt: Decimal
    var netWorth: Decimal
    var cashAssets: Decimal
    var investmentAssets: Decimal
    var physicalAssets: Decimal
    var monthlyDueTotal: Decimal
    var nextSevenDaysDue: Decimal

    var debtToAssetRatio: Double {
        guard totalAssets.doubleValue > 0 else { return 0 }
        return totalDebt.doubleValue / totalAssets.doubleValue
    }

    var cashCoverageRatio: Double {
        guard nextSevenDaysDue.doubleValue > 0 else { return 1 }
        return cashAssets.doubleValue / nextSevenDaysDue.doubleValue
    }
}

struct AppData: Codable {
    var bills: [DebtBill]
    var archives: [MonthlyArchive]
    var availableCash: Decimal
    var assets: [AssetItem]

    init(
        bills: [DebtBill],
        archives: [MonthlyArchive],
        availableCash: Decimal,
        assets: [AssetItem]? = nil
    ) {
        self.bills = bills
        self.archives = archives
        self.availableCash = availableCash
        self.assets = assets ?? [
            AssetItem(
                name: "可用现金",
                category: .cash,
                amount: availableCash,
                updatedAt: .now,
                note: "从负债系统现金余额生成"
            )
        ]
    }

    private enum CodingKeys: String, CodingKey {
        case bills
        case archives
        case availableCash
        case assets
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        bills = try container.decode([DebtBill].self, forKey: .bills)
        archives = try container.decode([MonthlyArchive].self, forKey: .archives)
        availableCash = try container.decodeIfPresent(Decimal.self, forKey: .availableCash) ?? 0
        assets = try container.decodeIfPresent([AssetItem].self, forKey: .assets) ?? [
            AssetItem(
                name: "可用现金",
                category: .cash,
                amount: availableCash,
                updatedAt: .now,
                note: "从旧版负债系统迁移"
            )
        ]
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(bills, forKey: .bills)
        try container.encode(archives, forKey: .archives)
        try container.encode(availableCash, forKey: .availableCash)
        try container.encode(assets, forKey: .assets)
    }
}

extension Decimal {
    var doubleValue: Double {
        NSDecimalNumber(decimal: self).doubleValue
    }
}

extension Date {
    static func appDate(_ year: Int, _ month: Int, _ day: Int) -> Date {
        Calendar.current.date(from: DateComponents(year: year, month: month, day: day)) ?? .now
    }
}

enum Formatters {
    static let currency: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.numberStyle = .currency
        formatter.maximumFractionDigits = 0
        return formatter
    }()

    static let decimal: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 2
        return formatter
    }()

    static let percent: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.numberStyle = .percent
        formatter.maximumFractionDigits = 0
        return formatter
    }()

    static let date: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "M月d日"
        return formatter
    }()

    static let month: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy年M月"
        return formatter
    }()

    static func currencyText(_ amount: Decimal) -> String {
        currency.string(from: NSDecimalNumber(decimal: amount)) ?? "¥0"
    }

    static func decimalText(_ amount: Decimal) -> String {
        NSDecimalNumber(decimal: amount).stringValue
    }

    static func percentText(_ value: Double) -> String {
        percent.string(from: NSNumber(value: value)) ?? "0%"
    }

    static func decimal(from text: String) -> Decimal {
        Decimal(string: text.replacingOccurrences(of: ",", with: "")) ?? 0
    }
}
