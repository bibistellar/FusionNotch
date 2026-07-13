//
//  AgentToolMark.swift
//  boringNotch
//
//  Brand marks for the supported agents. The two agents we actually hook — Claude Code
//  and Codex — get their vendor's official mark (vector assets, so they stay crisp at
//  the tiny sizes the notch uses). Everything else falls back to an initial.
//  Nominative use: the mark identifies whose session a row belongs to.
//

import OpenIslandCore
import SwiftUI

struct AgentToolMark: View {
    let tool: AgentTool
    var size: CGFloat = 24

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.24)
            .fill(Color(hex: tool.brandColorHex) ?? .gray)
            .frame(width: size, height: size)
            .overlay { glyph }
    }

    /// The asset-catalog name of the vendor's mark, if we ship one.
    private var logoAsset: String? {
        switch tool {
        case .claudeCode: "logo-claude"
        case .codex: "logo-openai"
        default: nil
        }
    }

    @ViewBuilder
    private var glyph: some View {
        if let logoAsset {
            Image(logoAsset)
                .renderingMode(.template)
                .resizable()
                .scaledToFit()
                .foregroundStyle(.white)
                .frame(width: size * 0.6, height: size * 0.6)
        } else {
            Text(tool.shortName.prefix(1))
                .font(.system(size: size * 0.45, weight: .bold))
                .foregroundStyle(.white)
        }
    }
}
