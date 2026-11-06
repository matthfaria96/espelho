import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated {
            MirrorService.shared.start()
            AppUpdater.shared.start()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated {
            MirrorService.shared.shutdown()
        }
    }

    /// With the menu bar icon on, closing the window keeps the receiver ready in the background.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        !UserDefaults.standard.bool(forKey: Prefs.menuBar)
    }
}

@main
struct EspelhoApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var service = MirrorService.shared
    @AppStorage(Prefs.menuBar) private var menuBar = true

    init() {
        Prefs.registerDefaults()
    }

    var body: some Scene {
        Window("Espelho", id: "main") {
            RootView()
                .environmentObject(service)
        }
        .windowStyle(.hiddenTitleBar)
        .windowBackgroundDragBehavior(.enabled)
        .defaultSize(width: WindowMetrics.welcome.width, height: WindowMetrics.welcome.height)
        .windowResizability(.contentMinSize)
        .commands { EspelhoCommands(service: service) }

        Settings {
            SettingsView()
                .environmentObject(service)
        }

        MenuBarExtra(isInserted: $menuBar) {
            MenuBarContent()
                .environmentObject(service)
        } label: {
            MenuBarLabel()
                .environmentObject(service)
        }
    }
}

enum WindowMetrics {
    static let welcome = CGSize(width: 780, height: 680)
}

struct EspelhoCommands: Commands {
    @ObservedObject var service: MirrorService
    @AppStorage(Prefs.keepOnTop) private var keepOnTop = false
    @AppStorage(Prefs.fitWindow) private var fitWindow = true

    var body: some Commands {
        CommandGroup(replacing: .newItem) {}

        CommandGroup(after: .appInfo) {
            if AppUpdater.shared.isAvailable { CheckForUpdatesButton() }
        }

        CommandGroup(after: .pasteboard) {
            Divider()
            Button("Copiar Tela do Aparelho") { service.captureScreenshot(copyOnly: true) }
                .keyboardShortcut("c", modifiers: [.command, .shift])
                .disabled(service.phase != .mirroring)
        }

        CommandMenu("Aparelho") {
            Button("Capturar Tela") { service.captureScreenshot() }
                .keyboardShortcut("s")
                .disabled(service.phase != .mirroring)
            Divider()
            Button("Desconectar") { service.disconnect() }
                .keyboardShortcut("d")
                .disabled(service.phase != .mirroring && service.phase != .connecting)
            Button("Reiniciar Receptor") { service.restart() }
                .keyboardShortcut("r", modifiers: [.command, .shift])
        }

        CommandGroup(before: .windowArrangement) {
            Toggle("Manter Acima das Outras Janelas", isOn: $keepOnTop)
                .keyboardShortcut("t", modifiers: [.command, .option])
            Toggle("Ajustar Janela ao Aparelho", isOn: $fitWindow)
            Button("Ajustar Tamanho Agora") {
                NotificationCenter.default.post(name: .espelhoFitWindow, object: nil)
            }
            .keyboardShortcut("0")
            .disabled(service.phase != .mirroring)
            Divider()
        }

        CommandGroup(replacing: .help) {
            Button("Tutorial: iPhone e iPad") {
                service.tutorialPlatform = .apple
                service.showOnboarding = true
            }
            Button("Tutorial: Android") {
                service.tutorialPlatform = .android
                service.showOnboarding = true
            }
            Button("Abrir Registro de Diagnóstico") {
                NSWorkspace.shared.open(MirrorService.logURL)
            }
            Divider()
            Link("Site do Espelho", destination: URL(string: "https://witchmymac.com/espelho/")!)
            Link("Código Fonte no GitHub", destination: URL(string: "https://github.com/matthfaria96/espelho")!)
        }
    }
}

extension Notification.Name {
    static let espelhoFitWindow = Notification.Name("espelhoFitWindow")
}
