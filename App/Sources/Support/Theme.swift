import SwiftUI

enum Theme {
    /// Do's signature gradient (indigo → violet → pink), used for the agent cursor and spinner.
    static let brand = [
        Color(red: 0.36, green: 0.42, blue: 1.00),
        Color(red: 0.62, green: 0.36, blue: 1.00),
        Color(red: 0.96, green: 0.38, blue: 0.74),
    ]
    static let brandGradient = LinearGradient(colors: brand, startPoint: .topLeading, endPoint: .bottomTrailing)
    static let warning = Color(red: 1.0, green: 0.62, blue: 0.20)
    static let danger = Color(red: 1.0, green: 0.36, blue: 0.36)
    static let success = Color(red: 0.30, green: 0.85, blue: 0.50)
}
