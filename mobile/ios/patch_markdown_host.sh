#!/bin/bash
# Replay the iOS markdown host patch onto a copy of Mob's label renderer.
# Stock Mob drops unknown props and draws text nodes as plain Text, so assistant
# markdown never reaches Swift. Hex deps are not the source of truth; iOS builds
# run this script and compile the copies.
set -euo pipefail

if [ "$#" -ne 5 ]; then
  echo "usage: patch_markdown_host.sh MOB_IOS_DIR OUT_HEADER OUT_IMPL OUT_NIF OUT_ROOT" >&2
  exit 2
fi

python3 - "$1" "$2" "$3" "$4" "$5" <<'PY'
import pathlib, sys

mob_ios, out_h, out_m, out_nif, out_root = map(pathlib.Path, sys.argv[1:])

def load(name):
    path = mob_ios / name
    if not path.is_file():
        sys.exit(f"missing {path}")
    return path.read_text(encoding="utf-8")

def ensure(text, old, new, label):
    if new in text:
        return text
    count = text.count(old)
    if count != 1:
        sys.exit(f"{label}: expected 1 anchor, found {count}")
    return text.replace(old, new, 1)

header = ensure(
    load("MobNode.h"),
    "@property(nonatomic) CGFloat letterSpacing;\n",
    "@property(nonatomic) CGFloat letterSpacing;\n"
    "// Handbeam: forwarded so assistant text can render markdown. Default NO.\n"
    "@property(nonatomic) BOOL markdown;\n"
    "@property(nonatomic) BOOL markdownStreaming;\n",
    "MobNode.h",
)

impl = ensure(
    load("MobNode.m"),
    "        _letterSpacing = 0.0;\n",
    "        _letterSpacing = 0.0;\n"
    "        _markdown = NO;\n"
    "        _markdownStreaming = NO;\n",
    "MobNode.m",
)

nif = load("mob_nif.m")
nif = ensure(
    nif,
    "    MOB_PROP_width,\n    MOB_PROP__COUNT\n",
    "    MOB_PROP_width,\n"
    "    MOB_PROP_markdown,\n"
    "    MOB_PROP_markdown_streaming,\n"
    "    MOB_PROP__COUNT\n",
    "mob_nif.m enum",
)
nif = ensure(
    nif,
    '[MOB_PROP_width] = @"width"};\n',
    '[MOB_PROP_width] = @"width",\n'
    '          [MOB_PROP_markdown] = @"markdown",\n'
    '          [MOB_PROP_markdown_streaming] = @"markdown_streaming"};\n',
    "mob_nif.m names",
)
nif = ensure(
    nif,
    "        id letterSpacing = pv[MOB_PROP_letter_spacing];\n"
    "        if (letterSpacing)\n"
    "            node.letterSpacing = [letterSpacing doubleValue];\n",
    "        id letterSpacing = pv[MOB_PROP_letter_spacing];\n"
    "        if (letterSpacing)\n"
    "            node.letterSpacing = [letterSpacing doubleValue];\n"
    "\n"
    "        id markdown = pv[MOB_PROP_markdown];\n"
    "        if (markdown)\n"
    "            node.markdown = [markdown boolValue];\n"
    "        id markdownStreaming = pv[MOB_PROP_markdown_streaming];\n"
    "        if (markdownStreaming)\n"
    "            node.markdownStreaming = [markdownStreaming boolValue];\n",
    "mob_nif.m assign",
)

root_old = """                let textShouldFill = node.fillWidth || node.textAlign == "center" || node.textAlign == "right"
                Text(node.text ?? "")
                    .font(node.resolvedFont)
                    .foregroundColor(node.textColor.map { Color($0) } ?? Color.primary)
                    .multilineTextAlignment(node.textAlignEnum)
                    .lineSpacing(node.computedLineSpacing)
                    .kerning(node.letterSpacing)
                    .ifLet(textShouldFill ? () : nil) { view, _ in
                        view.frame(maxWidth: .infinity, alignment: node.frameTextAlignment)
                    }
"""

root_new = """                let textShouldFill = node.fillWidth || node.textAlign == "center" || node.textAlign == "right"
                Group {
                    if node.markdown {
                        // Handbeam markdown. User bubbles stay on the plain Text path.
                        HandbeamMarkdownText(
                            source: node.text ?? "",
                            streaming: node.markdownStreaming,
                            fontSize: node.textSize > 0 ? node.textSize : 14,
                            color: node.textColor.map { Color($0) } ?? Color.primary
                        )
                        .multilineTextAlignment(node.textAlignEnum)
                        .frame(maxWidth: .infinity, alignment: node.frameTextAlignment)
                    } else {
                        Text(node.text ?? "")
                            .font(node.resolvedFont)
                            .foregroundColor(node.textColor.map { Color($0) } ?? Color.primary)
                            .multilineTextAlignment(node.textAlignEnum)
                            .lineSpacing(node.computedLineSpacing)
                            .kerning(node.letterSpacing)
                            .ifLet(textShouldFill ? () : nil) { view, _ in
                                view.frame(maxWidth: .infinity, alignment: node.frameTextAlignment)
                            }
                    }
                }
"""

root = load("MobRootView.swift")
if "HandbeamMarkdownText(" not in root:
    if root.count(root_old) != 1:
        sys.exit(f"MobRootView.swift: expected 1 label anchor, found {root.count(root_old)}")
    root = root.replace(root_old, root_new, 1)

for path, text in ((out_h, header), (out_m, impl), (out_nif, nif), (out_root, root)):
    path.write_text(text, encoding="utf-8")
PY
