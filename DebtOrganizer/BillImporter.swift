import Foundation
import UniformTypeIdentifiers
import zlib

struct BillImportResult {
    let insertedCount: Int
    let skippedCount: Int
    let warnings: [String]

    var message: String {
        var lines = ["已导入 \(insertedCount) 条账单。"]
        if skippedCount > 0 {
            lines.append("跳过 \(skippedCount) 行。")
        }
        if !warnings.isEmpty {
            lines.append(contentsOf: warnings.prefix(3))
        }
        return lines.joined(separator: "\n")
    }
}

struct ImportedBillBatch {
    let bills: [DebtBill]
    let skippedCount: Int
    let warnings: [String]
}

enum BillImportError: LocalizedError {
    case unsupportedFileType(String)
    case unreadableFile
    case missingHeaders([String])
    case noValidRows([String])
    case invalidWorkbook

    var errorDescription: String? {
        switch self {
        case .unsupportedFileType(let fileExtension):
            return "暂不支持 .\(fileExtension) 文件，请选择 .xlsx、.csv 或 .tsv。"
        case .unreadableFile:
            return "无法读取文件，请确认文件没有加密或损坏。"
        case .missingHeaders(let headers):
            return "缺少必要表头：\(headers.joined(separator: "、"))。"
        case .noValidRows(let warnings):
            if warnings.isEmpty {
                return "没有找到可导入的账单行。"
            }
            return "没有找到可导入的账单行。\n\(warnings.prefix(3).joined(separator: "\n"))"
        case .invalidWorkbook:
            return "无法解析 Excel 文件，请确认它是标准 .xlsx 工作簿。"
        }
    }
}

enum BillImporter {
    static let supportedContentTypes: [UTType] = [
        .xlsxWorkbook,
        .commaSeparatedText,
        .tabSeparatedText,
        .plainText
    ]

    static func importedBills(from url: URL) throws -> ImportedBillBatch {
        let fileExtension = url.pathExtension.lowercased()

        switch fileExtension {
        case "xlsx":
            return try importXLSX(from: url)
        case "csv":
            return try importDelimitedFile(from: url, delimiter: ",")
        case "tsv", "txt":
            return try importDelimitedFile(from: url, delimiter: fileExtension == "tsv" ? "\t" : nil)
        default:
            throw BillImportError.unsupportedFileType(fileExtension.isEmpty ? "未知" : fileExtension)
        }
    }

    private static func importDelimitedFile(from url: URL, delimiter: Character?) throws -> ImportedBillBatch {
        let data = try Data(contentsOf: url)
        guard let text = String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .utf16)
            ?? String(data: data, encoding: .gb18030) else {
            throw BillImportError.unreadableFile
        }

        let rows = parseDelimitedRows(text, delimiter: delimiter ?? detectedDelimiter(in: text))
        return try makeBills(from: rows)
    }

    private static func importXLSX(from url: URL) throws -> ImportedBillBatch {
        let archive = try XLSXArchive(url: url)
        let sharedStrings = try archive.sharedStrings()
        let rows = try archive.firstWorksheetRows(sharedStrings: sharedStrings)
        return try makeBills(from: rows)
    }

    private static func makeBills(from rows: [[String]]) throws -> ImportedBillBatch {
        guard let headerIndex = rows.prefix(10).indices.first(where: { headerMap(for: rows[$0]).hasRequiredHeaders }) else {
            throw BillImportError.missingHeaders(requiredHeaderNames)
        }

        let mapping = headerMap(for: rows[headerIndex])
        let dataRows = rows.dropFirst(headerIndex + 1)
        var bills: [DebtBill] = []
        var warnings: [String] = []
        var skippedCount = 0

        for (offset, row) in dataRows.enumerated() {
            let rowNumber = headerIndex + offset + 2
            if row.allSatisfy({ $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
                continue
            }

            func value(_ column: BillColumn) -> String {
                guard let index = mapping.columns[column], index < row.count else { return "" }
                return row[index].trimmingCharacters(in: .whitespacesAndNewlines)
            }

            let platform = value(.platform)
            guard !platform.isEmpty else {
                skippedCount += 1
                warnings.append("第 \(rowNumber) 行缺少平台。")
                continue
            }

            guard let amount = decimal(from: value(.amount)), amount > 0 else {
                skippedCount += 1
                warnings.append("第 \(rowNumber) 行金额无效。")
                continue
            }

            guard let dueDate = date(from: value(.dueDate)) else {
                skippedCount += 1
                warnings.append("第 \(rowNumber) 行还款日无效。")
                continue
            }

            let billType = value(.billType).isEmpty ? "消费" : value(.billType)
            let borrowDate = date(from: value(.borrowDate)) ?? dueDate
            let principal = decimal(from: value(.principal)) ?? amount
            let fee = decimal(from: value(.fee)) ?? 0

            bills.append(
                DebtBill(
                    platform: platform,
                    billType: billType,
                    borrowDate: borrowDate,
                    amount: amount,
                    principal: principal,
                    fee: fee,
                    dueDate: dueDate,
                    status: status(from: value(.status)),
                    autoDeduct: bool(from: value(.autoDeduct)),
                    note: value(.note)
                )
            )
        }

        guard !bills.isEmpty else {
            throw BillImportError.noValidRows(warnings)
        }

        return ImportedBillBatch(bills: bills, skippedCount: skippedCount, warnings: warnings)
    }

    private static func headerMap(for row: [String]) -> HeaderMap {
        var columns: [BillColumn: Int] = [:]
        for (index, title) in row.enumerated() {
            let normalizedTitle = normalizedHeader(title)
            guard !normalizedTitle.isEmpty else { continue }
            for column in BillColumn.allCases where columns[column] == nil {
                if column.aliases.contains(normalizedTitle) {
                    columns[column] = index
                }
            }
        }
        return HeaderMap(columns: columns)
    }

    private static var requiredHeaderNames: [String] {
        BillColumn.required.map(\.displayName)
    }

    private static func parseDelimitedRows(_ text: String, delimiter: Character) -> [[String]] {
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        let characters = Array(text)
        var index = 0
        var inQuotes = false

        while index < characters.count {
            let character = characters[index]
            if character == "\"" {
                if inQuotes, index + 1 < characters.count, characters[index + 1] == "\"" {
                    field.append("\"")
                    index += 1
                } else {
                    inQuotes.toggle()
                }
            } else if character == delimiter, !inQuotes {
                row.append(field)
                field = ""
            } else if (character == "\n" || character == "\r"), !inQuotes {
                if character == "\r", index + 1 < characters.count, characters[index + 1] == "\n" {
                    index += 1
                }
                row.append(field)
                rows.append(row)
                row = []
                field = ""
            } else {
                field.append(character)
            }
            index += 1
        }

        if !field.isEmpty || !row.isEmpty {
            row.append(field)
            rows.append(row)
        }

        return rows
    }

    private static func detectedDelimiter(in text: String) -> Character {
        let firstLine = text.split(whereSeparator: \.isNewline).first ?? ""
        return firstLine.filter { $0 == "\t" }.count > firstLine.filter { $0 == "," }.count ? "\t" : ","
    }

    private static func normalizedHeader(_ header: String) -> String {
        header
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "/", with: "")
            .replacingOccurrences(of: "／", with: "")
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: "_", with: "")
            .replacingOccurrences(of: "（", with: "")
            .replacingOccurrences(of: "）", with: "")
            .replacingOccurrences(of: "(", with: "")
            .replacingOccurrences(of: ")", with: "")
    }

    private static func decimal(from text: String) -> Decimal? {
        let filtered = text
            .replacingOccurrences(of: ",", with: "")
            .filter { "-0123456789.".contains($0) }
        guard !filtered.isEmpty else { return nil }
        return Decimal(string: String(filtered))
    }

    private static func date(from text: String) -> Date? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if let serial = Double(trimmed), serial > 1 {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .current
            let base = calendar.date(from: DateComponents(year: 1899, month: 12, day: 30))
            return base.flatMap { calendar.date(byAdding: .day, value: Int(serial.rounded(.down)), to: $0) }
        }

        let formats = [
            "yyyy-MM-dd",
            "yyyy/M/d",
            "yyyy.M.d",
            "yyyy年M月d日",
            "M/d/yyyy",
            "M/d/yy",
            "M月d日"
        ]

        for format in formats {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "zh_CN")
            formatter.dateFormat = format
            if let date = formatter.date(from: trimmed) {
                if format == "M月d日" {
                    let year = Calendar.current.component(.year, from: .now)
                    var components = Calendar.current.dateComponents([.month, .day], from: date)
                    components.year = year
                    return Calendar.current.date(from: components)
                }
                return date
            }
        }

        return nil
    }

    private static func status(from text: String) -> DebtStatus {
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let status = DebtStatus(rawValue: normalized) {
            return status
        }
        if normalized.contains("逾期") {
            return .overdue
        }
        if normalized.contains("部分") {
            return .partial
        }
        if normalized.contains("已") || normalized.contains("结清") || normalized.contains("完成") {
            return .paid
        }
        return .unpaid
    }

    private static func bool(from text: String) -> Bool {
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return ["1", "yes", "true", "y", "是", "有", "自动", "开启"].contains(normalized)
    }
}

private struct HeaderMap {
    let columns: [BillColumn: Int]

    var hasRequiredHeaders: Bool {
        BillColumn.required.allSatisfy { columns[$0] != nil }
    }
}

private enum BillColumn: CaseIterable {
    case platform
    case billType
    case borrowDate
    case amount
    case principal
    case fee
    case dueDate
    case status
    case autoDeduct
    case note

    static let required: [BillColumn] = [.platform, .amount, .dueDate]

    var displayName: String {
        switch self {
        case .platform: return "平台"
        case .billType: return "账单类型"
        case .borrowDate: return "消费/借款日期"
        case .amount: return "应还金额"
        case .principal: return "本金"
        case .fee: return "利息/手续费"
        case .dueDate: return "最晚还款日"
        case .status: return "状态"
        case .autoDeduct: return "自动扣款"
        case .note: return "备注"
        }
    }

    var aliases: Set<String> {
        let values: [String]
        switch self {
        case .platform:
            values = ["平台", "平台名称", "账单平台", "借款平台"]
        case .billType:
            values = ["账单类型", "类型", "类别", "借款类型", "消费类型"]
        case .borrowDate:
            values = ["消费借款日期", "消费日期", "借款日期", "产生日期", "发生日期"]
        case .amount:
            values = ["应还金额", "应还", "金额", "账单金额", "还款金额", "待还金额"]
        case .principal:
            values = ["本金", "借款本金", "消费本金"]
        case .fee:
            values = ["利息手续费", "手续费", "利息", "费用"]
        case .dueDate:
            values = ["最晚还款日", "还款日", "到期日", "应还日期", "截止日期"]
        case .status:
            values = ["状态", "还款状态"]
        case .autoDeduct:
            values = ["自动扣款", "是否自动扣款", "扣款"]
        case .note:
            values = ["备注", "说明", "备注说明"]
        }
        return Set(values.map(BillImporterNormalizedHeader.init).map(\.value))
    }
}

private struct BillImporterNormalizedHeader {
    let value: String

    init(_ header: String) {
        value = header
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "/", with: "")
            .replacingOccurrences(of: "／", with: "")
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: "_", with: "")
            .replacingOccurrences(of: "（", with: "")
            .replacingOccurrences(of: "）", with: "")
            .replacingOccurrences(of: "(", with: "")
            .replacingOccurrences(of: ")", with: "")
    }
}

private extension String.Encoding {
    static let gb18030 = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)))
}

private extension UTType {
    static let xlsxWorkbook = UTType(filenameExtension: "xlsx") ?? .data
}

private struct XLSXArchive {
    private struct Entry {
        let name: String
        let compressionMethod: UInt16
        let compressedSize: Int
        let uncompressedSize: Int
        let localHeaderOffset: Int
    }

    private let data: Data
    private let entries: [String: Entry]

    init(url: URL) throws {
        data = try Data(contentsOf: url)
        entries = try XLSXArchive.readEntries(from: data)
    }

    func sharedStrings() throws -> [String] {
        guard let data = try fileData(named: "xl/sharedStrings.xml") else {
            return []
        }
        let parser = XMLParser(data: data)
        let delegate = SharedStringsParserDelegate()
        parser.delegate = delegate
        guard parser.parse() else {
            throw BillImportError.invalidWorkbook
        }
        return delegate.strings
    }

    func firstWorksheetRows(sharedStrings: [String]) throws -> [[String]] {
        let sheetName = entries.keys.sorted().first {
            $0.hasPrefix("xl/worksheets/sheet") && $0.hasSuffix(".xml")
        }
        guard let sheetName, let data = try fileData(named: sheetName) else {
            throw BillImportError.invalidWorkbook
        }

        let parser = XMLParser(data: data)
        let delegate = WorksheetParserDelegate(sharedStrings: sharedStrings)
        parser.delegate = delegate
        guard parser.parse() else {
            throw BillImportError.invalidWorkbook
        }
        return delegate.rows
    }

    private func fileData(named name: String) throws -> Data? {
        guard let entry = entries[name] else { return nil }
        guard data.count >= entry.localHeaderOffset + 30,
              data.uint32(at: entry.localHeaderOffset) == 0x04034b50 else {
            throw BillImportError.invalidWorkbook
        }

        let fileNameLength = Int(data.uint16(at: entry.localHeaderOffset + 26))
        let extraFieldLength = Int(data.uint16(at: entry.localHeaderOffset + 28))
        let dataStart = entry.localHeaderOffset + 30 + fileNameLength + extraFieldLength
        let dataEnd = dataStart + entry.compressedSize
        guard dataEnd <= data.count else {
            throw BillImportError.invalidWorkbook
        }

        let compressedData = data.subdata(in: dataStart..<dataEnd)
        switch entry.compressionMethod {
        case 0:
            return compressedData
        case 8:
            return try inflate(compressedData, expectedSize: entry.uncompressedSize)
        default:
            throw BillImportError.invalidWorkbook
        }
    }

    private static func readEntries(from data: Data) throws -> [String: Entry] {
        guard data.count >= 22 else {
            throw BillImportError.invalidWorkbook
        }

        let searchStart = max(0, data.count - 65_557)
        var eocdOffset: Int?
        var offset = data.count - 22
        while offset >= searchStart {
            if data.uint32(at: offset) == 0x06054b50 {
                eocdOffset = offset
                break
            }
            offset -= 1
        }

        guard let eocdOffset else {
            throw BillImportError.invalidWorkbook
        }

        let entryCount = Int(data.uint16(at: eocdOffset + 10))
        var centralOffset = Int(data.uint32(at: eocdOffset + 16))
        var entries: [String: Entry] = [:]

        for _ in 0..<entryCount {
            guard centralOffset + 46 <= data.count,
                  data.uint32(at: centralOffset) == 0x02014b50 else {
                throw BillImportError.invalidWorkbook
            }

            let compressionMethod = data.uint16(at: centralOffset + 10)
            let compressedSize = Int(data.uint32(at: centralOffset + 20))
            let uncompressedSize = Int(data.uint32(at: centralOffset + 24))
            let fileNameLength = Int(data.uint16(at: centralOffset + 28))
            let extraFieldLength = Int(data.uint16(at: centralOffset + 30))
            let fileCommentLength = Int(data.uint16(at: centralOffset + 32))
            let localHeaderOffset = Int(data.uint32(at: centralOffset + 42))

            let nameStart = centralOffset + 46
            let nameEnd = nameStart + fileNameLength
            guard nameEnd <= data.count,
                  let name = String(data: data.subdata(in: nameStart..<nameEnd), encoding: .utf8) else {
                throw BillImportError.invalidWorkbook
            }

            entries[name] = Entry(
                name: name,
                compressionMethod: compressionMethod,
                compressedSize: compressedSize,
                uncompressedSize: uncompressedSize,
                localHeaderOffset: localHeaderOffset
            )
            centralOffset = nameEnd + extraFieldLength + fileCommentLength
        }

        return entries
    }

    private func inflate(_ compressedData: Data, expectedSize: Int) throws -> Data {
        var stream = z_stream()
        let initStatus = inflateInit2_(&stream, -MAX_WBITS, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size))
        guard initStatus == Z_OK else {
            throw BillImportError.invalidWorkbook
        }
        defer { inflateEnd(&stream) }

        return try compressedData.withUnsafeBytes { inputPointer in
            guard let inputBase = inputPointer.bindMemory(to: Bytef.self).baseAddress else {
                return Data()
            }

            stream.next_in = UnsafeMutablePointer<Bytef>(mutating: inputBase)
            stream.avail_in = uInt(compressedData.count)

            var output = Data(count: max(expectedSize, 64 * 1024))

            while true {
                if Int(stream.total_out) == output.count {
                    output.count *= 2
                }

                let outputOffset = Int(stream.total_out)
                let outputAvailable = output.count - outputOffset
                let status = output.withUnsafeMutableBytes { outputPointer -> Int32 in
                    guard let outputBase = outputPointer.bindMemory(to: Bytef.self).baseAddress else {
                        return Z_STREAM_ERROR
                    }
                    stream.next_out = outputBase.advanced(by: outputOffset)
                    stream.avail_out = uInt(outputAvailable)
                    return zlib.inflate(&stream, Z_NO_FLUSH)
                }

                if status == Z_STREAM_END {
                    output.count = Int(stream.total_out)
                    return output
                }

                guard status == Z_OK else {
                    throw BillImportError.invalidWorkbook
                }
            }
        }
    }
}

private final class SharedStringsParserDelegate: NSObject, XMLParserDelegate {
    private(set) var strings: [String] = []
    private var currentString = ""
    private var currentText = ""
    private var isReadingText = false

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        if elementName == "si" {
            currentString = ""
        } else if elementName == "t" {
            currentText = ""
            isReadingText = true
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if isReadingText {
            currentText.append(string)
        }
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        if elementName == "t" {
            currentString.append(currentText)
            isReadingText = false
        } else if elementName == "si" {
            strings.append(currentString)
        }
    }
}

private final class WorksheetParserDelegate: NSObject, XMLParserDelegate {
    private let sharedStrings: [String]
    private(set) var rows: [[String]] = []

    private var currentRow: [Int: String] = [:]
    private var currentColumnIndex: Int?
    private var currentCellType: String?
    private var currentValue = ""
    private var currentInlineText = ""
    private var isReadingValue = false
    private var isReadingInlineText = false

    init(sharedStrings: [String]) {
        self.sharedStrings = sharedStrings
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        switch elementName {
        case "row":
            currentRow = [:]
        case "c":
            currentColumnIndex = attributeDict["r"].flatMap(Self.columnIndex)
            currentCellType = attributeDict["t"]
            currentValue = ""
            currentInlineText = ""
        case "v":
            isReadingValue = true
        case "t":
            if currentCellType == "inlineStr" {
                isReadingInlineText = true
            }
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if isReadingValue {
            currentValue.append(string)
        } else if isReadingInlineText {
            currentInlineText.append(string)
        }
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        switch elementName {
        case "v":
            isReadingValue = false
        case "t":
            isReadingInlineText = false
        case "c":
            guard let currentColumnIndex else { return }
            currentRow[currentColumnIndex] = resolvedCellValue()
        case "row":
            guard !currentRow.isEmpty else { return }
            let maxColumn = currentRow.keys.max() ?? 0
            rows.append((0...maxColumn).map { currentRow[$0] ?? "" })
        default:
            break
        }
    }

    private func resolvedCellValue() -> String {
        switch currentCellType {
        case "s":
            guard let index = Int(currentValue.trimmingCharacters(in: .whitespacesAndNewlines)),
                  sharedStrings.indices.contains(index) else {
                return ""
            }
            return sharedStrings[index]
        case "inlineStr":
            return currentInlineText
        default:
            return currentValue
        }
    }

    private static func columnIndex(from cellReference: String) -> Int? {
        let letters = cellReference.prefix { $0.isLetter }
        guard !letters.isEmpty else { return nil }

        var index = 0
        for scalar in letters.uppercased().unicodeScalars {
            let ascii = Int(scalar.value)
            guard (65...90).contains(ascii) else { return nil }
            index = index * 26 + ascii - 64
        }
        return index - 1
    }
}

private extension Data {
    func uint16(at offset: Int) -> UInt16 {
        UInt16(self[offset]) | UInt16(self[offset + 1]) << 8
    }

    func uint32(at offset: Int) -> UInt32 {
        UInt32(self[offset])
            | UInt32(self[offset + 1]) << 8
            | UInt32(self[offset + 2]) << 16
            | UInt32(self[offset + 3]) << 24
    }
}
