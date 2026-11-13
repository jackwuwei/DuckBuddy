#!/usr/bin/env python3
"""从 icons.json 生成两端的图标枚举（文案 strings.json 两端运行时直接读取，不需要生成）。"""
import json, pathlib, re
root = pathlib.Path(__file__).resolve().parent
icons = {k: v for k, v in json.loads((root / "icons.json").read_text()).items() if not k.startswith("_")}

swift = ["// 由 app/shared/gen.py 从 icons.json 生成，勿手改。", "", "enum Icon: String, CaseIterable {"]
swift += [f"    case {k}" for k in icons]
swift += ["", "    var path: String {", "        switch self {"]
swift += [f'        case .{k}: "{v}"' for k, v in icons.items()]
swift += ["        }", "    }", "}", ""]
(root.parent / "ios/DuckBuddy/Design/Icons.generated.swift").write_text("\n".join(swift))

def kt(name):  # Kotlin 枚举常量用大写下划线
    return re.sub(r"(?<!^)(?=[A-Z])", "_", name).upper()
kotlin = ["// 由 app/shared/gen.py 从 icons.json 生成，勿手改。", "package robot.duckbuddy.microduck.design", "",
          "enum class Icon(val path: String) {"]
kotlin += [f'    {kt(k)}("{v}"),' for k, v in icons.items()]
kotlin[-1] = kotlin[-1][:-1] + ";"
kotlin += ["}", ""]
out = root.parent / "android/app/src/main/java/robot/duckbuddy/microduck/design/Icons.kt"
out.parent.mkdir(parents=True, exist_ok=True)
out.write_text("\n".join(kotlin))
print(f"{len(icons)} icons → iOS, Android")
