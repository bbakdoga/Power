import SwiftUI

/// The app's look: light/dark mode, accent color and (for colorful themes) a tinted
/// background on the main screens.
enum AppTheme: String, CaseIterable, Identifiable {
    case system, light, dark, amoled, pink, ocean

    static let storageKey = "appTheme"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: return String(localized: "System")
        case .light: return String(localized: "Light")
        case .dark: return String(localized: "Dark")
        case .amoled: return String(localized: "AMOLED Black")
        case .pink: return String(localized: "Pink")
        case .ocean: return String(localized: "Ocean")
        }
    }

    /// nil follows the iPhone's Light/Dark setting.
    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light, .pink: return .light
        case .dark, .amoled, .ocean: return .dark
        }
    }

    /// Buttons, links, charts, highlights.
    var accent: Color {
        switch self {
        case .system, .light, .dark, .amoled: return Color("AccentColor")
        case .pink: return Color(red: 0.93, green: 0.29, blue: 0.56)
        case .ocean: return Color(red: 0.25, green: 0.78, blue: 0.86)
        }
    }

    /// Screen background behind lists; nil keeps the standard iOS background.
    var background: Color? {
        switch self {
        case .system, .light, .dark: return nil
        case .amoled: return .black
        case .pink: return Color(red: 1.0, green: 0.92, blue: 0.95)
        case .ocean: return Color(red: 0.04, green: 0.11, blue: 0.20)
        }
    }

    /// Background of list rows; nil keeps the standard iOS row color.
    var rowBackground: Color? {
        self == .amoled ? .black : nil
    }

    /// Colors for the preview swatch in Settings.
    var swatch: [Color] {
        switch self {
        case .system: return [.white, .black]
        case .light: return [.white, Color(white: 0.92)]
        case .dark: return [Color(white: 0.12), Color(white: 0.2)]
        case .amoled: return [.black, .black]
        case .pink: return [Color(red: 1.0, green: 0.85, blue: 0.91), accent]
        case .ocean: return [Color(red: 0.04, green: 0.11, blue: 0.20), accent]
        }
    }
}

/// Puts the theme's background behind a screen's list or form.
private struct ThemedScreen: ViewModifier {
    @AppStorage(AppTheme.storageKey) private var theme: AppTheme = .system

    func body(content: Content) -> some View {
        if let background = theme.background {
            content
                .scrollContentBackground(.hidden)
                .background(background.ignoresSafeArea())
        } else {
            content
        }
    }
}

/// Gives a list section's rows the theme's row color (pure black for AMOLED).
private struct ThemedRows: ViewModifier {
    @AppStorage(AppTheme.storageKey) private var theme: AppTheme = .system

    func body(content: Content) -> some View {
        content.listRowBackground(theme.rowBackground)
    }
}

extension View {
    /// Applies the current theme's row color to this list section.
    func themedRows() -> some View {
        modifier(ThemedRows())
    }

    /// Applies the current theme's background to this screen.
    func themedScreen() -> some View {
        modifier(ThemedScreen())
    }
}

