import SwiftUI

/// "Trocar de aparelho": every way to put another device on screen, from anywhere.
struct DeviceSwitchItems: View {
    @EnvironmentObject private var service: MirrorService
    @ObservedObject private var android = AndroidManager.shared

    var body: some View {
        let others = android.devices.filter { $0.isReady && !(service.source == .android && service.deviceName == $0.name) }
        Section("Android") {
            if others.isEmpty {
                Text(android.knownIDs.isEmpty ? "Nenhum Android pareado" : "Nenhum Android por perto")
            }
            ForEach(others) { device in
                Button {
                    service.startAndroid(device)
                } label: {
                    Label("Espelhar \(device.name)", systemImage: device.symbol)
                }
            }
            Button("Conectar outro Android…") {
                service.disconnectForSwitch()
                UserDefaults.standard.set("android", forKey: Prefs.welcomeTab)
                android.beginPairing()
            }
        }
        Section("iPhone e iPad") {
            Text("No aparelho: Central de Controle › Espelhar Tela › “\(service.advertisedName)”")
        }
    }
}

/// The glass button in the mirror view's control bar.
struct DeviceSwitchButton: View {
    @ObservedObject private var android = AndroidManager.shared

    var body: some View {
        Menu {
            DeviceSwitchItems()
        } label: {
            Image(systemName: "arrow.left.arrow.right")
                .font(.system(size: 15, weight: .semibold))
                .frame(width: 40, height: 40)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .glassEffect(.regular.interactive(), in: .circle)
        .help("Trocar de aparelho")
        .onAppear { Task { await android.refresh() } }
    }
}
