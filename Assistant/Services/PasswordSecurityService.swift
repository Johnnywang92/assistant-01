import Foundation
import Security

/// 离线强密码生成与密码强度评估工具
public enum PasswordSecurityService {

    /// 生成高强度随机密码
    /// - Parameters:
    ///   - length: 密码长度（默认 16 位）
    ///   - includeUppercase: 包含大写字母
    ///   - includeLowercase: 包含小写字母
    ///   - includeDigits: 包含数字
    ///   - includeSymbols: 包含特殊符号
    /// - Returns: 生成的高强度密码字符串
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
}
