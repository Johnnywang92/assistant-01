import Foundation

/// 批量导入回执：成功条数 + 被跳过行的物理行号与原因。
public struct BatchImportReport: Equatable, Sendable {
    public struct Skipped: Equatable, Sendable {
        public let line: Int
        public let reason: String

        public init(line: Int, reason: String) {
            self.line = line
            self.reason = reason
        }
    }

    public var imported: Int
    public var skipped: [Skipped]

    public init(imported: Int = 0, skipped: [Skipped] = []) {
        self.imported = imported
        self.skipped = skipped
    }
}

/// 纪念日 CSV 的逐行校验结果（尚未落库）。
public struct AnniversaryImportRow: Equatable, Sendable {
    public let line: Int
    public let title: String
    public let date: Date
    public let category: String
    public let notes: String?
}

/// 密码 CSV 的逐行校验结果（尚未加密与落库）。
public struct PasswordImportRow: Equatable, Sendable {
    public let line: Int
    public let title: String
    public let account: String
    public let password: String
    public let category: String
    public let notes: String?
}

/// CSV 批量导入的纯校验层：把文本切成可落库的行，并记录哪些行被跳过、为什么。
/// 落库与加密由调用方负责，这里不做任何持久化。
public enum BatchCSVImport {
    /// 纪念日格式：名称, 日期(yyyy-MM-dd), 分类(可选), 备注(可选)
    public static func anniversaries(
        from text: String,
        timeZone: TimeZone = .current
    ) -> (rows: [AnniversaryImportRow], skipped: [BatchImportReport.Skipped]) {
        var rows: [AnniversaryImportRow] = []
        var skipped: [BatchImportReport.Skipped] = []

        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd"

        for record in CSVParser.parse(text) {
            let fields = record.fields
            guard fields.count >= 2 else {
                skipped.append(.init(line: record.line, reason: "字段不足 2 列（名称, 日期）"))
                continue
            }
            let title = fields[0]
            guard !title.isEmpty else {
                skipped.append(.init(line: record.line, reason: "名称为空"))
                continue
            }
            guard let date = parseDay(fields[1], formatter: formatter) else {
                skipped.append(.init(line: record.line, reason: "日期无效（需要 yyyy-MM-dd）：\(fields[1])"))
                continue
            }
            rows.append(AnniversaryImportRow(
                line: record.line,
                title: title,
                date: date,
                category: fields.count >= 3 && !fields[2].isEmpty ? fields[2] : "纪念日",
                notes: fields.count >= 4 && !fields[3].isEmpty ? fields[3] : nil
            ))
        }
        return (rows, skipped)
    }

    /// 密码格式：服务名, 账号, 密码, 分类(可选), 备注(可选)
    public static func passwords(
        from text: String
    ) -> (rows: [PasswordImportRow], skipped: [BatchImportReport.Skipped]) {
        var rows: [PasswordImportRow] = []
        var skipped: [BatchImportReport.Skipped] = []

        for record in CSVParser.parse(text) {
            let fields = record.fields
            guard fields.count >= 3 else {
                skipped.append(.init(line: record.line, reason: "字段不足 3 列（服务名, 账号, 密码）"))
                continue
            }
            let title = fields[0]
            let account = fields[1]
            let password = fields[2]
            guard !title.isEmpty else {
                skipped.append(.init(line: record.line, reason: "服务名为空"))
                continue
            }
            guard !account.isEmpty else {
                skipped.append(.init(line: record.line, reason: "账号为空"))
                continue
            }
            guard !password.isEmpty else {
                skipped.append(.init(line: record.line, reason: "密码为空"))
                continue
            }
            rows.append(PasswordImportRow(
                line: record.line,
                title: title,
                account: account,
                password: password,
                category: fields.count >= 4 && !fields[3].isEmpty ? fields[3] : "日常账号",
                notes: fields.count >= 5 && !fields[4].isEmpty ? fields[4] : nil
            ))
        }
        return (rows, skipped)
    }
}

/// `DateFormatter` 会把 `2022-02-31` 顺延成 `2022-03-03`，回写比对才能识破溢出的日期。
private func parseDay(_ text: String, formatter: DateFormatter) -> Date? {
    guard let date = formatter.date(from: text) else { return nil }
    return formatter.string(from: date) == text ? date : nil
}
