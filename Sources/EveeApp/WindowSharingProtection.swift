import AppKit
import SwiftUI

struct WindowSharingProtectionInstaller: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        protect(view)
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        protect(view)
    }

    private func protect(_ view: NSView) {
        DispatchQueue.main.async {
            view.window?.sharingType = .none
        }
    }
}
