import SwiftUI

/// Menu bar icon: reflects the state and brings the window back when a device connects.
struct MenuBarLabel: View {
    @EnvironmentObject private var service: MirrorService
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Image(systemName: symbol)
            .onChange(of: service.phase) { _, phase in
                if phase == .connecting || phase == .mirroring { MenuBarActions.showWindow(openWindow) }
            }
    }

    private var symbol: String {
        switch service.phase {
        case .mirroring: "rectangle.on.rectangle.circle.fill"
        case .failed: "exclamationmark.triangle"
        default: "rectangle.on.rectangle"
        }
    }
}

struct MenuBarContent: View {
    @EnvironmentObject private var service: MirrorService
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Text(status)
        if service.phase == .mirroring {
            Button("Capturar Tela") { service.captureScreenshot() }
            Button("Desconectar") { service.disconnect() }
        }
        Divider()
        Menu("Trocar de Aparelho") { DeviceSwitchItems() }
        Divider()
        Button("Mostrar Janela") { MenuBarActions.showWindow(openWindow) }
        Button("Ajustes…") {
            NSApp.activate()
            openSettings()
        }
        Button("Reiniciar Receptor") { service.restart() }
        Divider()
        Button("Sair do Espelho") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }

    private var status: String {
        switch service.phase {
        case .starting: "Iniciando…"
        case .ready: "Pronto · visível como “\(service.advertisedName)”"
        case .connecting: "Conectando \(service.deviceName ?? "aparelho")…"
        case .mirroring: "Espelhando \(service.deviceName ?? "aparelho")"
        case .failed: "Receptor parado"
        }
    }
}

enum MenuBarActions {
    @MainActor
    static func showWindow(_ openWindow: OpenWindowAction) {
        if let window = NSApp.windows.first(where: { $0.identifier?.rawValue.hasPrefix("main") == true && $0.canBecomeMain }) {
            if window.isMiniaturized { window.deminiaturize(nil) }
            window.makeKeyAndOrderFront(nil)
        } else {
            openWindow(id: "main")
        }
        NSApp.activate()
    }
}
