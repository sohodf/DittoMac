import Foundation

enum RelativeDate {
    static func string(from date: Date) -> String {
        let now = Date()
        let diff = now.timeIntervalSince(date)

        if diff < 60 { return "just now" }
        if diff < 3600 {
            let mins = Int(diff / 60)
            return "\(mins) min ago"
        }
        if diff < 86400 {
            let hours = Int(diff / 3600)
            return "\(hours)h ago"
        }
        if diff < 172800 { return "Yesterday" }
        if diff < 604800 {
            let days = Int(diff / 86400)
            return "\(days) days ago"
        }

        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .none
        return formatter.string(from: date)
    }
}
