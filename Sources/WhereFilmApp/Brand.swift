import SwiftUI

enum WhereFilmBrand {
    static let inkWell = Color(red: 11 / 255, green: 20 / 255, blue: 33 / 255)
    static let ophelia = Color(red: 40 / 255, green: 48 / 255, blue: 65 / 255)
    static let brocade = Color(red: 52 / 255, green: 57 / 255, blue: 74 / 255)
    static let vapor = Color(red: 181 / 255, green: 185 / 255, blue: 188 / 255)
    static let silver = Color(red: 218 / 255, green: 222 / 255, blue: 228 / 255)
    static let blue = Color(red: 113 / 255, green: 138 / 255, blue: 190 / 255)

    static let background = LinearGradient(
        colors: [inkWell, Color.black.opacity(0.96), ophelia.opacity(0.68)],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    static let searchGlow = LinearGradient(
        colors: [blue.opacity(0.86), vapor.opacity(0.52), brocade.opacity(0.9)],
        startPoint: .leading,
        endPoint: .trailing
    )
}

struct GlassPanel: ViewModifier {
    var cornerRadius: CGFloat = 22

    func body(content: Content) -> some View {
        content
            .background(WhereFilmBrand.ophelia.opacity(0.58))
            .background(.ultraThinMaterial.opacity(0.32))
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(WhereFilmBrand.vapor.opacity(0.17), lineWidth: 1)
            }
            .shadow(color: .black.opacity(0.34), radius: 28, y: 18)
    }
}

extension View {
    func whereFilmGlass(cornerRadius: CGFloat = 22) -> some View {
        modifier(GlassPanel(cornerRadius: cornerRadius))
    }
}
