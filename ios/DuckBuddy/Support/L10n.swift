import Foundation

/// 全局语言。文案只有一份：`app/shared/i18n/strings.json`（两端共用），打包进 App。
enum Lang: String, CaseIterable, Codable {
    case zh, en
}

final class L10n {
    static let shared = L10n()
    private var table: [String: [String: String]] = [:]
    var lang: Lang = .zh

    private init() {
        if let url = Bundle.main.url(forResource: "strings", withExtension: "json"),
           let data = try? Data(contentsOf: url),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: [String: String]] {
            table = json
        }
    }

    func text(_ key: String) -> String {
        table[key]?[lang.rawValue] ?? table[key]?["zh"] ?? key
    }
}

/// 取文案；`args` 依次替换 `{0}`、`{1}`…
func L(_ key: String, _ args: CustomStringConvertible...) -> String {
    var s = L10n.shared.text(key)
    for (i, a) in args.enumerated() { s = s.replacingOccurrences(of: "{\(i)}", with: a.description) }
    return s
}
