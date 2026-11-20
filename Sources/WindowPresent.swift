import AppKit

extension NSWindow {
    /// Met la fenêtre au premier plan même si l'appli (accessoire, sans Dock) n'est pas encore active : depuis un menu ou un
    /// panneau, l'activation est asynchrone et `makeKeyAndOrderFront` seul laisse la première fenêtre invisible.
    @MainActor func present() {
        NSApp.activate()
        orderFrontRegardless()
        makeKeyAndOrderFront(nil)
        DispatchQueue.main.async { [weak self] in // activation pas encore effective : on la redemande au tour suivant
            guard let self, self.isVisible, !self.isKeyWindow else { return }
            NSApp.activate()
            self.makeKeyAndOrderFront(nil)
        }
    }
}

extension NSWindow {
    /// Centre la fenêtre (taille réduite si besoin) au milieu de la zone visible de l'écran où se trouve la souris.
    @MainActor func centerOnScreen() {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main ?? NSScreen.screens[0]
        let v = screen.visibleFrame
        var f = frame
        f.size.width = min(f.width, v.width); f.size.height = min(f.height, v.height)
        f.origin = NSPoint(x: v.midX - f.width / 2, y: v.midY - f.height / 2)
        setFrame(f, display: true)
    }
}
