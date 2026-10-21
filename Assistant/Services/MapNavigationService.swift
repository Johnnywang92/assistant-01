import Foundation
import UIKit

enum MapNavigationService {
    static func openDirections(to destination: String) {
        let trimmed = destination.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let encoded = trimmed.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "https://maps.apple.com/?daddr=\(encoded)&dirflg=d") else { return }
        UIApplication.shared.open(url)
    }
}
