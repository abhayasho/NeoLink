import Foundation

enum X11Helpers {
    static func environmentWithX11(_ env: [String: String]) -> [String: String] {
        var updated = env
        if updated["DISPLAY"] == nil {
            updated["DISPLAY"] = ":0"
        }
        return updated
    }
}

