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

struct DebtMetrics: Equatable {
    var monthlyDueTotal: Decimal
    var nextSevenDaysDue: Decimal
    var paidAmount: Decimal
    var unpaidAmount: Decimal
    var totalDebt: Decimal
    var availableCash: Decimal
    var cashPressure: Decimal
}

struct AppData: Codable {
    var bills: [DebtBill]
    var archives: [MonthlyArchive]
    var availableCash: Decimal
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

    static func decimal(from text: String) -> Decimal {
        Decimal(string: text.replacingOccurrences(of: ",", with: "")) ?? 0
    }
}
