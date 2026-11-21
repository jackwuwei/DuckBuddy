import SwiftUI

/// 情绪动作在托盘和手柄页上的样子。名字和顺序来自 core `shippedEmotions`，这里只管图标、颜色、文案。
enum EmotionStyle {
    static func label(_ name: String) -> String {
        ["yes": L("yes"), "no": L("no"), "excited": L("excited")][name] ?? L("emo_" + name)
    }

    static func icon(_ name: String) -> Icon {
        switch name {
        case "yes": .check
        case "no": .x
        case "excited": .excited
        case "laugh": .emoLaugh
        case "curious": .emoCurious
        case "mmh": .emoMmh
        case "sad": .emoSad
        case "angry": .emoAngry
        case "impatient": .emoImpatient
        case "defiant": .emoDefiant
        case "mock": .emoMock
        case "devastated": .emoDevastated
        case "yes_fast": .emoYesFast
        default: .emotion
        }
    }

    static func color(_ name: String) -> Color {
        switch name {
        case "yes", "yes_fast", "curious": Palette.cyan
        case "no", "angry", "defiant": Palette.pink
        case "excited", "laugh", "impatient": Palette.orange
        case "mock", "mmh": Palette.yellow
        default: Palette.purple
        }
    }
}

/// 玩法的图标和文案键。
enum GameStyle {
    static func key(_ g: Game) -> String {
        switch g {
        case .laser: "laser"
        case .soccer: "soccer"
        case .autonomous: "autonomous"
        }
    }

    static func icon(_ g: Game) -> Icon {
        switch g {
        case .laser: .gameLaser
        case .soccer: .gameSoccer
        case .autonomous: .gameAuto
        }
    }
}
