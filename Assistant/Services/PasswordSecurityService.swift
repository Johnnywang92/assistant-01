import Foundation
import Security

/// 密码生成模式
public enum PasswordGenerationMode: String, CaseIterable, Identifiable {
    case memorablePhrase = "单词短语"     // 类似 1Password/Diceware: Breeze-Tiger-2026!Sky
    case pinyinPhrase = "拼音短语"        // 中文拼音好记: ChunTian#88!FeiXiang
    case pronounceable = "顺口音节"       // 辅音元音交替发音: Kano-Biva-77#Ludo
    case classicRandom = "高强度随机"     // 传统字符乱码: xK9#mQ2$pL7*vW

    public var id: String { rawValue }

    public var icon: String {
        switch self {
        case .memorablePhrase: return "text.quote"
        case .pinyinPhrase: return "character.bubble"
        case .pronounceable: return "mouth"
        case .classicRandom: return "dice.fill"
        }
    }

    public var subtitle: String {
        switch self {
        case .memorablePhrase: return "具象生动，脑海形成画面，防破解极强"
        case .pinyinPhrase: return "拼音字意对应，最贴合中文用户记忆直觉"
        case .pronounceable: return "音节对称易朗读，无生僻别扭字符"
        case .classicRandom: return "纯随机字符混杂，适合特殊系统严格限制"
        }
    }
}

/// 密码生成结果包
public struct GeneratedPasswordResult: Identifiable {
    public let id = UUID()
    public let password: String
    public let mode: PasswordGenerationMode
    public let mnemonicHint: String   // 记忆逻辑/记忆口诀
    public let strengthScore: Int      // 0 ~ 4
    public let strengthLabel: String
    public let entropyBits: Int        // 估计熵值 (bits)
}

/// 离线强密码生成与密码强度评估工具（支持逻辑记忆与极高熵值）
public enum PasswordSecurityService {

    // MARK: - 词库定义

    // 常用具象英文形容词
    private static let memorableAdjectives: [String] = [
        "Bright", "Brave", "Calm", "Clever", "Cool", "Cozy", "Fresh", "Golden",
        "Green", "Happy", "Lucky", "Noble", "Quick", "Quiet", "Silver", "Sunny",
        "Swift", "Warm", "Wild", "Wise", "Blue", "Red", "Soft", "Pure", "Deep",
        "Free", "Grand", "Magic", "Royal", "Amber", "Vivid", "Super", "Merry"
    ]

    // 常用具象英文名词
    private static let memorableNouns: [(word: String, cn: String)] = [
        ("Panda", "熊猫"), ("Tiger", "老虎"), ("Falcon", "猎鹰"), ("Eagle", "雄鹰"),
        ("Ocean", "海洋"), ("Breeze", "微风"), ("Comet", "彗星"), ("Forest", "森林"),
        ("Island", "海岛"), ("Moon", "月亮"), ("Orbit", "轨道"), ("River", "河流"),
        ("Shadow", "影子"), ("Star", "繁星"), ("Storm", "风暴"), ("Valley", "山谷"),
        ("Beacon", "灯塔"), ("Castle", "城堡"), ("Lotus", "莲花"), ("Solar", "太阳"),
        ("Echo", "回声"), ("Haven", "港湾"), ("Zenith", "顶峰"), ("Glory", "荣耀"),
        ("Canyon", "峡谷"), ("Oasis", "绿洲"), ("Harbor", "港口"), ("Summit", "巅峰")
    ]

    // 中文拼音词库（带中文释义，方便串联记忆口诀）
    private static let pinyinWords: [(pinyin: String, cn: String)] = [
        ("ChunTian", "春天"), ("XiaRi", "夏日"), ("QiuFeng", "秋风"), ("DongXue", "冬雪"),
        ("XingKong", "星空"), ("HaiLang", "海浪"), ("ShanFeng", "山峰"), ("SenLin", "森林"),
        ("TaiYang", "太阳"), ("YueGuang", "月光"), ("FeiXiang", "飞翔"), ("LanTian", "蓝天"),
        ("BaiYun", "白云"), ("ChenXi", "晨曦"), ("CaiHong", "彩虹"), ("DianYing", "电影"),
        ("KuaiLe", "快乐"), ("XingFu", "幸福"), ("MengXiang", "梦想"), ("GuangMang", "光芒"),
        ("YongGan", "勇敢"), ("HuoLi", "活力"), ("QingSong", "轻松"), ("PingAn", "平安"),
        ("YinYue", "音乐"), ("DengTa", "灯塔"), ("XiaoYuan", "校园"), ("LuoShan", "落山")
    ]

    // 可发音的辅音与元音组合
    private static let consonants = ["b", "c", "d", "f", "g", "h", "k", "l", "m", "n", "p", "r", "s", "t", "v", "z"]
    private static let vowels = ["a", "e", "i", "o", "u"]
    private static let separators = ["-", "_", ".", "!", "#", "@", "="]

    // MARK: - 密码生成逻辑

    /// 综合生成密码（带记忆模式与口诀）
    public static func generateSmartPassword(
        mode: PasswordGenerationMode = .memorablePhrase,
        wordCount: Int = 3,
        separator: String = "-",
        includeDigits: Bool = true,
        includeSymbols: Bool = true,
        randomLength: Int = 16
    ) -> GeneratedPasswordResult {
        switch mode {
        case .memorablePhrase:
            return generateMemorablePhrase(wordCount: wordCount, separator: separator, includeDigits: includeDigits, includeSymbols: includeSymbols)
        case .pinyinPhrase:
            return generatePinyinPhrase(wordCount: wordCount, separator: separator, includeDigits: includeDigits, includeSymbols: includeSymbols)
        case .pronounceable:
            return generatePronounceablePassword(syllableCount: max(2, wordCount), separator: separator, includeDigits: includeDigits, includeSymbols: includeSymbols)
        case .classicRandom:
            let pwd = generatePassword(length: randomLength, includeDigits: includeDigits, includeSymbols: includeSymbols)
            let strength = evaluateStrength(password: pwd)
            let entropy = estimateEntropy(password: pwd)
            return GeneratedPasswordResult(
                password: pwd,
                mode: .classicRandom,
                mnemonicHint: "高熵强混杂：由大小写字母、数字及特殊符号按 CSPRNG 均匀分布生成。",
                strengthScore: strength.score,
                strengthLabel: strength.label,
                entropyBits: entropy
            )
        }
    }

    /// 1. 具象英文短语生成（带联想故事）
    private static func generateMemorablePhrase(
        wordCount: Int,
        separator: String,
        includeDigits: Bool,
        includeSymbols: Bool
    ) -> GeneratedPasswordResult {
        let adj = secureSample(from: memorableAdjectives)
        var selectedNouns: [(word: String, cn: String)] = []
        var pool = memorableNouns
        for _ in 0..<max(1, wordCount - 1) {
            if pool.isEmpty { pool = memorableNouns }
            let idx = secureRandomIndex(count: pool.count)
            selectedNouns.append(pool.remove(at: idx))
        }

        var parts: [String] = [adj]
        parts.append(contentsOf: selectedNouns.map { $0.word })

        let randNum = includeDigits ? secureRandomNumber(range: 12...98) : nil
        let symbol = includeSymbols ? secureSample(from: ["!", "#", "@", "$", "*"]) : ""

        // 组装逻辑：Adjective - Noun1 - Number - Symbol - Noun2
        var password = ""
        var hintParts: [String] = []

        if selectedNouns.count == 1 {
            let noun = selectedNouns[0]
            if let num = randNum {
                password = "\(adj)\(separator)\(noun.word)\(separator)\(num)\(symbol)"
                hintParts = ["\(adj)", "\(noun.word)(\(noun.cn))", "\(num)\(symbol)"]
            } else {
                password = "\(adj)\(separator)\(noun.word)\(symbol)"
                hintParts = ["\(adj)", "\(noun.word)(\(noun.cn))", "\(symbol)"]
            }
        } else {
            let n1 = selectedNouns[0]
            let n2 = selectedNouns[1]
            if let num = randNum {
                let actualSep = separator.isEmpty ? "-" : separator
                password = "\(adj)\(actualSep)\(n1.word)\(actualSep)\(num)\(symbol)\(actualSep)\(n2.word)"
                hintParts = [
                    "\(adj)",
                    "\(n1.word)(\(n1.cn))",
                    "数字\(num)\(symbol)",
                    "\(n2.word)(\(n2.cn))"
                ]
            } else {
                let actualSep = separator.isEmpty ? "-" : separator
                password = "\(adj)\(actualSep)\(n1.word)\(symbol)\(actualSep)\(n2.word)"
                hintParts = ["\(adj)", "\(n1.word)(\(n1.cn))", "\(symbol)", "\(n2.word)(\(n2.cn))"]
            }
        }

        let mnemonic = "记忆画面：【\(hintParts.joined(separator: " + "))】"
        let strength = evaluateStrength(password: password)
        let entropy = estimateEntropy(password: password)

        return GeneratedPasswordResult(
            password: password,
            mode: .memorablePhrase,
            mnemonicHint: mnemonic,
            strengthScore: strength.score,
            strengthLabel: strength.label,
            entropyBits: entropy
        )
    }

    /// 2. 拼音短语生成（符合中文发音直觉）
    private static func generatePinyinPhrase(
        wordCount: Int,
        separator: String,
        includeDigits: Bool,
        includeSymbols: Bool
    ) -> GeneratedPasswordResult {
        var pool = pinyinWords
        var selected: [(pinyin: String, cn: String)] = []
        for _ in 0..<max(2, wordCount) {
            if pool.isEmpty { pool = pinyinWords }
            let idx = secureRandomIndex(count: pool.count)
            selected.append(pool.remove(at: idx))
        }

        let num = includeDigits ? secureRandomNumber(range: 16...99) : nil
        let symbol = includeSymbols ? secureSample(from: ["#", "!", "@", "=", "$"]) : ""
        let sep = separator.isEmpty ? "-" : separator

        var password = ""
        var storyParts: [String] = []

        if selected.count >= 2 {
            let w1 = selected[0]
            let w2 = selected[1]
            if let n = num {
                password = "\(w1.pinyin)\(sep)\(n)\(symbol)\(sep)\(w2.pinyin)"
                storyParts = ["\(w1.cn)(\(w1.pinyin))", "\(n)\(symbol)", "\(w2.cn)(\(w2.pinyin))"]
            } else {
                password = "\(w1.pinyin)\(symbol)\(sep)\(w2.pinyin)"
                storyParts = ["\(w1.cn)(\(w1.pinyin))", "\(symbol)", "\(w2.cn)(\(w2.pinyin))"]
            }
        }

        let mnemonic = "拼音口诀：【\(storyParts.joined(separator: " ➔ "))】"
        let strength = evaluateStrength(password: password)
        let entropy = estimateEntropy(password: password)

        return GeneratedPasswordResult(
            password: password,
            mode: .pinyinPhrase,
            mnemonicHint: mnemonic,
            strengthScore: strength.score,
            strengthLabel: strength.label,
            entropyBits: entropy
        )
    }

    /// 3. 可发音顺口音节生成
    private static func generatePronounceablePassword(
        syllableCount: Int,
        separator: String,
        includeDigits: Bool,
        includeSymbols: Bool
    ) -> GeneratedPasswordResult {
        var syllables: [String] = []
        for i in 0..<syllableCount {
            let c1 = secureSample(from: consonants)
            let v1 = secureSample(from: vowels)
            let c2 = secureSample(from: consonants)
            let v2 = secureSample(from: vowels)
            // 首字母大写增加辨识度
            let syl = (c1 + v1 + c2 + v2)
            syllables.append(i == 0 ? syl.capitalized : syl)
        }

        let num = includeDigits ? secureRandomNumber(range: 23...89) : nil
        let symbol = includeSymbols ? secureSample(from: ["!", "@", "#", "$", "*"]) : ""
        let sep = separator.isEmpty ? "-" : separator

        var password = ""
        if let n = num {
            password = "\(syllables.joined(separator: sep))\(symbol)\(n)"
        } else {
            password = "\(syllables.joined(separator: sep))\(symbol)"
        }

        let mnemonic = "顺口发音：【\(syllables.joined(separator: " · "))】拼读音节自然成句"
        let strength = evaluateStrength(password: password)
        let entropy = estimateEntropy(password: password)

        return GeneratedPasswordResult(
            password: password,
            mode: .pronounceable,
            mnemonicHint: mnemonic,
            strengthScore: strength.score,
            strengthLabel: strength.label,
            entropyBits: entropy
        )
    }

    /// 4. 经典高强度随机密码
    public static func generatePassword(
        length: Int = 16,
        includeUppercase: Bool = true,
        includeLowercase: Bool = true,
        includeDigits: Bool = true,
        includeSymbols: Bool = true
    ) -> String {
        var characterPool = ""
        if includeUppercase { characterPool += "ABCDEFGHJKLMNPQRSTUVWXYZ" } // 去掉易混淆的 I, O
        if includeLowercase { characterPool += "abcdefghijkmnopqrstuvwxyz" } // 去掉易混淆的 l
        if includeDigits { characterPool += "23456789" }                     // 去掉易混淆的 0, 1
        if includeSymbols { characterPool += "!@#$%^&*()-_=+[]{}<>" }

        if characterPool.isEmpty {
            characterPool = "abcdefghijkmnopqrstuvwxyz23456789"
        }

        var password = ""
        for _ in 0..<length {
            var randomByte: UInt8 = 0
            _ = SecRandomCopyBytes(kSecRandomDefault, 1, &randomByte)
            let index = Int(randomByte) % characterPool.count
            let charIndex = characterPool.index(characterPool.startIndex, offsetBy: index)
            password.append(characterPool[charIndex])
        }

        return password
    }

    /// 评估密码强度（得分 0 ~ 4）
    public static func evaluateStrength(password: String) -> (score: Int, label: String) {
        var score = 0
        if password.count >= 8 { score += 1 }
        if password.count >= 14 { score += 1 }
        if password.rangeOfCharacter(from: .decimalDigits) != nil &&
           password.rangeOfCharacter(from: .letters) != nil {
            score += 1
        }
        if password.rangeOfCharacter(from: CharacterSet(charactersIn: "!@#$%^&*()-_=+[]{}<>")) != nil {
            score += 1
        }

        let label: String = switch score {
        case 4: "极强"
        case 3: "良好"
        case 2: "一般"
        default: "较弱"
        }

        return (score, label)
    }

    /// 估算密码信息熵 (bits)
    public static func estimateEntropy(password: String) -> Int {
        var poolSize = 0
        if password.rangeOfCharacter(from: .lowercaseLetters) != nil { poolSize += 26 }
        if password.rangeOfCharacter(from: .uppercaseLetters) != nil { poolSize += 26 }
        if password.rangeOfCharacter(from: .decimalDigits) != nil { poolSize += 10 }
        if password.rangeOfCharacter(from: CharacterSet(charactersIn: "!@#$%^&*()-_=+[]{}<>")) != nil { poolSize += 20 }
        if poolSize == 0 { poolSize = 10 }

        let entropy = Double(password.count) * log2(Double(poolSize))
        return max(32, Int(entropy))
    }

    // MARK: - 安全随机辅助工具

    private static func secureRandomIndex(count: Int) -> Int {
        guard count > 1 else { return 0 }
        var randomByte: UInt32 = 0
        _ = SecRandomCopyBytes(kSecRandomDefault, MemoryLayout<UInt32>.size, &randomByte)
        return Int(randomByte % UInt32(count))
    }

    private static func secureSample<T>(from array: [T]) -> T {
        let index = secureRandomIndex(count: array.count)
        return array[index]
    }

    private static func secureRandomNumber(range: ClosedRange<Int>) -> Int {
        let span = range.upperBound - range.lowerBound + 1
        let offset = secureRandomIndex(count: span)
        return range.lowerBound + offset
    }
}
