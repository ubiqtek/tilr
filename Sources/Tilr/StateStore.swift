import Combine
import Foundation

final class StateStore: ObservableObject {
    @Published private(set) var activeSpace: String? = nil   // display name

    func setActiveSpace(_ name: String?) {
        DispatchQueue.main.async { self.activeSpace = name }
    }
}
