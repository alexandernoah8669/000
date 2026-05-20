import Foundation
import SwiftUI
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

struct BillImportTemplateDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.xlsxWorkbook] }
    static var writableContentTypes: [UTType] { [.xlsxWorkbook] }

    init() {}

    init(configuration: ReadConfiguration) throws {}

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: BillImportTemplateBuilder.makeWorkbookData())
    }
}

private enum BillImportTemplateBuilder {
    private static let headers = [
        "平台",
        "账单类型",
        "消费/借款日期",
        "应还金额",
        "本金",
        "利息/手续费",
        "最晚还款日",
        "状态",
        "自动扣款",
        "备注"
    ]

    private static let guideRows = [
        ["字段", "是否必填", "填写说明", "示例"],
        ["平台", "必填", "账单所属平台或账户名称。", "花呗"],
        ["账单类型", "可选", "不填时默认导入为消费。", "消费分期"],
        ["消费/借款日期", "可选", "支持 2026-05-20、2026/5/20、2026年5月20日。", "2026-05-20"],
        ["应还金额", "必填", "填写大于 0 的数字，可带千分位或货币符号。", "1280"],
        ["本金", "可选", "不填时默认等于应还金额。", "1220"],
        ["利息/手续费", "可选", "不填时默认 0。", "60"],
        ["最晚还款日", "必填", "支持日期文本或 Excel 日期单元格。", "2026-05-31"],
        ["状态", "可选", "支持：未还、已还、逾期、部分还款；不填默认未还。", "未还"],
        ["自动扣款", "可选", "填写 是/否、true/false、1/0；不填默认否。", "是"],
        ["备注", "可选", "补充账单说明。", "手机分期第 2 期"],
        ["回导说明", "", "导入时只读取第一张工作表，请在“账单导入”表填写，不要修改表头。", ""]
    ]

    static func makeWorkbookData() -> Data {
        let files: [(String, Data)] = [
            ("[Content_Types].xml", xmlData(contentTypesXML)),
            ("_rels/.rels", xmlData(rootRelationshipsXML)),
            ("docProps/core.xml", xmlData(corePropertiesXML)),
            ("docProps/app.xml", xmlData(appPropertiesXML)),
            ("xl/workbook.xml", xmlData(workbookXML)),
            ("xl/_rels/workbook.xml.rels", xmlData(workbookRelationshipsXML)),
            ("xl/styles.xml", xmlData(stylesXML)),
            ("xl/worksheets/sheet1.xml", xmlData(importSheetXML)),
            ("xl/worksheets/sheet2.xml", xmlData(guideSheetXML))
        ]
        return ZipArchiveWriter.makeArchive(files: files)
    }

    private static var contentTypesXML: String {
        """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
          <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
          <Default Extension="xml" ContentType="application/xml"/>
          <Override PartName="/docProps/app.xml" ContentType="application/vnd.openxmlformats-officedocument.extended-properties+xml"/>
          <Override PartName="/docProps/core.xml" ContentType="application/vnd.openxmlformats-package.core-properties+xml"/>
          <Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>
          <Override PartName="/xl/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"/>
          <Override PartName="/xl/worksheets/sheet1.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>
          <Override PartName="/xl/worksheets/sheet2.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>
        </Types>
        """
    }

    private static var rootRelationshipsXML: String {
        """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
          <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/>
          <Relationship Id="rId2" Type="http://schemas.openxmlformats.org/package/2006/relationships/metadata/core-properties" Target="docProps/core.xml"/>
          <Relationship Id="rId3" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/extended-properties" Target="docProps/app.xml"/>
        </Relationships>
        """
    }

    private static var corePropertiesXML: String {
        let timestamp = ISO8601DateFormatter().string(from: Date())
        return """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <cp:coreProperties xmlns:cp="http://schemas.openxmlformats.org/package/2006/metadata/core-properties" xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:dcterms="http://purl.org/dc/terms/" xmlns:dcmitype="http://purl.org/dc/dcmitype/" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
          <dc:title>账单导入模板</dc:title>
          <dc:creator>DebtOrganizer</dc:creator>
          <cp:lastModifiedBy>DebtOrganizer</cp:lastModifiedBy>
          <dcterms:created xsi:type="dcterms:W3CDTF">\(timestamp)</dcterms:created>
          <dcterms:modified xsi:type="dcterms:W3CDTF">\(timestamp)</dcterms:modified>
        </cp:coreProperties>
        """
    }

    private static var appPropertiesXML: String {
        """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Properties xmlns="http://schemas.openxmlformats.org/officeDocument/2006/extended-properties" xmlns:vt="http://schemas.openxmlformats.org/officeDocument/2006/docPropsVTypes">
          <Application>DebtOrganizer</Application>
          <DocSecurity>0</DocSecurity>
          <ScaleCrop>false</ScaleCrop>
          <HeadingPairs><vt:vector size="2" baseType="variant"><vt:variant><vt:lpstr>Worksheets</vt:lpstr></vt:variant><vt:variant><vt:i4>2</vt:i4></vt:variant></vt:vector></HeadingPairs>
          <TitlesOfParts><vt:vector size="2" baseType="lpstr"><vt:lpstr>账单导入</vt:lpstr><vt:lpstr>填写说明</vt:lpstr></vt:vector></TitlesOfParts>
        </Properties>
        """
    }

    private static var workbookXML: String {
        """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">
          <sheets>
            <sheet name="账单导入" sheetId="1" r:id="rId1"/>
            <sheet name="填写说明" sheetId="2" r:id="rId2"/>
          </sheets>
        </workbook>
        """
    }

    private static var workbookRelationshipsXML: String {
        """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
          <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet1.xml"/>
          <Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet2.xml"/>
          <Relationship Id="rId3" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/>
        </Relationships>
        """
    }

    private static var stylesXML: String {
        """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <styleSheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">
          <fonts count="2">
            <font><sz val="11"/><color theme="1"/><name val="Calibri"/><family val="2"/></font>
            <font><b/><sz val="11"/><color theme="1"/><name val="Calibri"/><family val="2"/></font>
          </fonts>
          <fills count="3">
            <fill><patternFill patternType="none"/></fill>
            <fill><patternFill patternType="gray125"/></fill>
            <fill><patternFill patternType="solid"><fgColor rgb="FFEAF2FF"/><bgColor indexed="64"/></patternFill></fill>
          </fills>
          <borders count="2">
            <border><left/><right/><top/><bottom/><diagonal/></border>
            <border><left style="thin"><color rgb="FFD9E2EC"/></left><right style="thin"><color rgb="FFD9E2EC"/></right><top style="thin"><color rgb="FFD9E2EC"/></top><bottom style="thin"><color rgb="FFD9E2EC"/></bottom><diagonal/></border>
          </borders>
          <cellStyleXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0"/></cellStyleXfs>
          <cellXfs count="3">
            <xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0"/>
            <xf numFmtId="0" fontId="1" fillId="2" borderId="1" xfId="0" applyFont="1" applyFill="1" applyBorder="1"/>
            <xf numFmtId="0" fontId="0" fillId="0" borderId="1" xfId="0" applyBorder="1"/>
          </cellXfs>
          <cellStyles count="1"><cellStyle name="Normal" xfId="0" builtinId="0"/></cellStyles>
        </styleSheet>
        """
    }

    private static var importSheetXML: String {
        let rows = rowXML(values: headers, rowIndex: 1, styleIndex: 1)
        return """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">
          <dimension ref="A1:J1000"/>
          <sheetViews><sheetView workbookViewId="0"><pane ySplit="1" topLeftCell="A2" activePane="bottomLeft" state="frozen"/></sheetView></sheetViews>
          <sheetFormatPr defaultRowHeight="18"/>
          \(columnWidthsXML)
          <sheetData>
            \(rows)
          </sheetData>
          <autoFilter ref="A1:J1"/>
          <dataValidations count="2">
            <dataValidation type="list" allowBlank="1" showErrorMessage="1" sqref="H2:H1000"><formula1>"未还,已还,逾期,部分还款"</formula1></dataValidation>
            <dataValidation type="list" allowBlank="1" showErrorMessage="1" sqref="I2:I1000"><formula1>"是,否"</formula1></dataValidation>
          </dataValidations>
        </worksheet>
        """
    }

    private static var guideSheetXML: String {
        let rows = guideRows.enumerated()
            .map { rowXML(values: $0.element, rowIndex: $0.offset + 1, styleIndex: $0.offset == 0 ? 1 : 2) }
            .joined(separator: "\n")
        return """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">
          <dimension ref="A1:D\(guideRows.count)"/>
          <sheetViews><sheetView workbookViewId="0"><pane ySplit="1" topLeftCell="A2" activePane="bottomLeft" state="frozen"/></sheetView></sheetViews>
          <sheetFormatPr defaultRowHeight="20"/>
          <cols>
            <col min="1" max="1" width="18" customWidth="1"/>
            <col min="2" max="2" width="12" customWidth="1"/>
            <col min="3" max="3" width="56" customWidth="1"/>
            <col min="4" max="4" width="22" customWidth="1"/>
          </cols>
          <sheetData>
            \(rows)
          </sheetData>
        </worksheet>
        """
    }

    private static var columnWidthsXML: String {
        """
        <cols>
          <col min="1" max="1" width="16" customWidth="1"/>
          <col min="2" max="2" width="16" customWidth="1"/>
          <col min="3" max="3" width="18" customWidth="1"/>
          <col min="4" max="6" width="14" customWidth="1"/>
          <col min="7" max="7" width="18" customWidth="1"/>
          <col min="8" max="9" width="14" customWidth="1"/>
          <col min="10" max="10" width="28" customWidth="1"/>
        </cols>
        """
    }

    private static func rowXML(values: [String], rowIndex: Int, styleIndex: Int) -> String {
        let cells = values.enumerated().map { index, value in
            cellXML(value: value, columnIndex: index + 1, rowIndex: rowIndex, styleIndex: styleIndex)
        }
        .joined()
        return "<row r=\"\(rowIndex)\">\(cells)</row>"
    }

    private static func cellXML(value: String, columnIndex: Int, rowIndex: Int, styleIndex: Int) -> String {
        let reference = "\(columnName(columnIndex))\(rowIndex)"
        return "<c r=\"\(reference)\" t=\"inlineStr\" s=\"\(styleIndex)\"><is><t>\(escapedXML(value))</t></is></c>"
    }

    private static func columnName(_ index: Int) -> String {
        var number = index
        var letters = ""
        while number > 0 {
            let remainder = (number - 1) % 26
            letters.insert(Character(UnicodeScalar(65 + remainder) ?? "A"), at: letters.startIndex)
            number = (number - 1) / 26
        }
        return letters
    }

    private static func escapedXML(_ text: String) -> String {
        text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }

    private static func xmlData(_ xml: String) -> Data {
        Data(xml.utf8)
    }
}

private enum ZipArchiveWriter {
    private struct CentralEntry {
        let nameData: Data
        let checksum: UInt32
        let size: UInt32
        let localHeaderOffset: UInt32
    }

    static func makeArchive(files: [(String, Data)]) -> Data {
        var archive = Data()
        var centralEntries: [CentralEntry] = []

        for (name, data) in files {
            let nameData = Data(name.utf8)
            let checksum = checksum(for: data)
            let size = UInt32(data.count)
            let localHeaderOffset = UInt32(archive.count)

            archive.appendUInt32(0x04034b50)
            archive.appendUInt16(20)
            archive.appendUInt16(0)
            archive.appendUInt16(0)
            archive.appendUInt16(0)
            archive.appendUInt16(0)
            archive.appendUInt32(checksum)
            archive.appendUInt32(size)
            archive.appendUInt32(size)
            archive.appendUInt16(UInt16(nameData.count))
            archive.appendUInt16(0)
            archive.append(nameData)
            archive.append(data)

            centralEntries.append(
                CentralEntry(
                    nameData: nameData,
                    checksum: checksum,
                    size: size,
                    localHeaderOffset: localHeaderOffset
                )
            )
        }

        let centralDirectoryOffset = UInt32(archive.count)
        for entry in centralEntries {
            archive.appendUInt32(0x02014b50)
            archive.appendUInt16(20)
            archive.appendUInt16(20)
            archive.appendUInt16(0)
            archive.appendUInt16(0)
            archive.appendUInt16(0)
            archive.appendUInt16(0)
            archive.appendUInt32(entry.checksum)
            archive.appendUInt32(entry.size)
            archive.appendUInt32(entry.size)
            archive.appendUInt16(UInt16(entry.nameData.count))
            archive.appendUInt16(0)
            archive.appendUInt16(0)
            archive.appendUInt16(0)
            archive.appendUInt16(0)
            archive.appendUInt32(0)
            archive.appendUInt32(entry.localHeaderOffset)
            archive.append(entry.nameData)
        }

        let centralDirectorySize = UInt32(archive.count) - centralDirectoryOffset
        let entryCount = UInt16(centralEntries.count)
        archive.appendUInt32(0x06054b50)
        archive.appendUInt16(0)
        archive.appendUInt16(0)
        archive.appendUInt16(entryCount)
        archive.appendUInt16(entryCount)
        archive.appendUInt32(centralDirectorySize)
        archive.appendUInt32(centralDirectoryOffset)
        archive.appendUInt16(0)

        return archive
    }

    private static func checksum(for data: Data) -> UInt32 {
        data.withUnsafeBytes { pointer in
            guard let baseAddress = pointer.bindMemory(to: Bytef.self).baseAddress else {
                return UInt32(zlib.crc32(0, nil, 0))
            }
            return UInt32(zlib.crc32(0, baseAddress, uInt(data.count)))
        }
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

extension UTType {
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

    mutating func appendUInt16(_ value: UInt16) {
        var littleEndianValue = value.littleEndian
        Swift.withUnsafeBytes(of: &littleEndianValue) { append(contentsOf: $0) }
    }

    mutating func appendUInt32(_ value: UInt32) {
        var littleEndianValue = value.littleEndian
        Swift.withUnsafeBytes(of: &littleEndianValue) { append(contentsOf: $0) }
    }
}
