#if os(iOS)
import SwiftUI

struct IOSMoreView: View {
    var body: some View {
        NavigationStack { SettingsHost() }
    }
}
#endif
