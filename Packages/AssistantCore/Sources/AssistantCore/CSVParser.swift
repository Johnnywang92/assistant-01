import Foundation

/// 一条 CSV 逻辑记录。`line` 是该记录起始的物理行号（1 起），用于导入回执定位。
public struct CSVRecord: Equatable, Sendable {
    public let line: Int
    public let fields: [String]

    public init(line: Int, fields: [String]) {
        self.line = line
        self.fields = fields
    }
}

/// RFC 4180 风格的最小 CSV 解析器。
///
/// 只做导入真正需要的事：双引号包裹、字段内 `""` 转义、引号内的逗号与换行、
/// CRLF/CR/LF 三种行尾、UTF-8 BOM。不做类型推断也不抛错——格式不合法的行
/// 由调用方按字段数与取值判定，并计入「跳过」回执。
public enum CSVParser {
    public static func parse(_ text: String) -> [CSVRecord] {
        var records: [CSVRecord] = []
        var fields: [String] = []
        var field = ""
        var fieldWasQuoted = false
        var inQuotes = false
        var line = 1
        var recordStartLine = 1

        var characters = Array(text)
        if characters.first == "\u{FEFF}" {
            characters.removeFirst()
        }

        func endField() {
            // 引号字段原样保留空格；裸字段沿用旧行为去掉首尾空白
            fields.append(fieldWasQuoted ? field : field.trimmingCharacters(in: .whitespaces))
            field = ""
            fieldWasQuoted = false
        }

        func endRecord() {
            endField()
            // 纯空白行不算数据行，也不计入「跳过」
            if !fields.allSatisfy({ $0.trimmingCharacters(in: .whitespaces).isEmpty }) {
                records.append(CSVRecord(line: recordStartLine, fields: fields))
            }
            fields.removeAll(keepingCapacity: true)
        }

        func advanceLine() {
            line += 1
            recordStartLine = line
        }

        var index = 0
        while index < characters.count {
            let character = characters[index]

            if inQuotes {
                if character == "\"" {
                    // 连续两个引号表示一个字面引号；单个引号结束引用
                    if index + 1 < characters.count, characters[index + 1] == "\"" {
                        field.append("\"")
                        index += 2
                        continue
                    }
                    inQuotes = false
                    index += 1
                    continue
                }
                if character == "\n" || character == "\r" || character == "\r\n" {
                    line += 1
                }
                field.append(character)
                index += 1
                continue
            }

            switch character {
            case "\"":
                // 允许字段前有空格再开引号（部分导出工具会这样写）
                if !fieldWasQuoted && field.trimmingCharacters(in: .whitespaces).isEmpty {
                    field = ""
                    fieldWasQuoted = true
                    inQuotes = true
                } else {
                    // 字段中间的引号按字面量处理，不吞掉后面的内容
                    field.append(character)
                }
            case ",":
                endField()
            // Swift 的 Character 会把 CRLF 合成一个字符，三种行尾都要认
            case "\r\n", "\r", "\n":
                endRecord()
                advanceLine()
            default:
                field.append(character)
            }
            index += 1
        }

        // 文件末尾没有换行时，补上最后一条记录
        if !field.isEmpty || !fields.isEmpty || fieldWasQuoted {
            endRecord()
        }
        return records
    }
}
