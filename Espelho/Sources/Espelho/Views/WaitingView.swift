import SwiftUI

/// Shown while no device is mirroring: status, how to connect, PIN when needed.
struct WaitingView: View {
    @EnvironmentObject private var service: MirrorService
    @Environment(\.openSettings) private var openSettings
    @AppStorage(Prefs.welcomeTab) private var tab = "apple"
    @ObservedObject private var android = AndroidManager.shared

    private var androidTab: Bool { tab == "android" }

    var body: some View {
        ZStack {
            AmbientBackground(active: service.phase == .connecting)

            VStack(spacing: 0) {
                Spacer(minLength: 30)

                Beacon(phase: service.phase, symbol: beaconSymbol)
                    .frame(width: 150, height: 150)

                VStack(spacing: 8) {
                    Text(title)
                        .font(.system(size: 30, weight: .bold, design: .rounded))
                        .contentTransition(.opacity)
                    Text(subtitle)
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: 440)
                        .contentTransition(.opacity)
                }
                .padding(.top, 14)

                Picker("Aparelho", selection: $tab.animation(.smooth)) {
                    Label("iPhone e iPad", systemImage: "apple.logo").tag("apple")
                    Label("Android", systemImage: "smartphone").tag("android")
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 280)
                .padding(.top, 18)

                Group {
                    if let pin = service.pin {
                        PinCard(pin: pin)
                    } else if case .failed = service.phase {
                        Button {
                            if service.needsRepair { service.repair() } else { service.restart() }
                        } label: {
                            Label(service.needsRepair ? "Reparar" : "Tentar de novo",
                                  systemImage: service.needsRepair ? "wrench.and.screwdriver" : "arrow.clockwise")
                                .padding(.horizontal, 8)
                        }
                        .buttonStyle(.glassProminent)
                        .controlSize(.large)
                    } else if androidTab {
                        AndroidCard()
                    } else {
                        VStack(spacing: 14) {
                            StatusPill(phase: service.phase, name: service.advertisedName)
                            StepsCard(name: service.advertisedName)
                        }
                    }
                }
                .padding(.top, 18)
                .transition(.blurReplace)

                Spacer(minLength: 24)

                HStack(spacing: 10) {
                    Button {
                        service.tutorialPlatform = androidTab ? .android : .apple
                        service.showOnboarding = true
                    } label: {
                        Label(androidTab ? "Tutorial do Android" : "Tutorial do iPhone e iPad",
                              systemImage: "questionmark.circle")
                    }
                    Button {
                        openSettings()
                    } label: {
                        Label("Ajustes", systemImage: "gearshape")
                    }
                }
                .buttonStyle(.glass)
                .controlSize(.large)

                Text(androidTab ? "Pelo Wi-Fi, o Android e este Mac precisam estar na mesma rede."
                                : "O aparelho e este Mac precisam estar na mesma rede Wi-Fi.")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .padding(.top, 12)
                    .padding(.bottom, 22)
            }
            .padding(.horizontal, 32)
        }
        .animation(.smooth(duration: 0.4), value: service.phase)
        .animation(.smooth(duration: 0.4), value: service.pin)
        .onAppear { android.wantsDiscovery = androidTab }
        .onDisappear { android.wantsDiscovery = false }
        .onChange(of: tab) { _, _ in android.wantsDiscovery = androidTab }
        .sheet(isPresented: $android.showPairing, onDismiss: { android.closePairing() }) {
            AndroidPairingView()
        }
    }

    private var beaconSymbol: String {
        if service.phase == .connecting { return service.deviceSymbol }
        return androidTab ? "smartphone" : "iphone"
    }

    private var title: String {
        switch service.phase {
        case .starting: "Preparando…"
        case .ready: "Pronto para espelhar"
        case .connecting: "Conectando \(service.deviceName ?? "aparelho")…"
        case .mirroring: ""
        case .failed: "Algo deu errado"
        }
    }

    private var subtitle: String {
        switch service.phase {
        case .starting:
            "Ligando o receptor de espelhamento."
        case .ready:
            androidTab
                ? "Veja e controle seu Android aqui, com o mouse e o teclado do Mac."
                : "Veja a tela do seu iPhone ou iPad aqui, sem cabos e sem instalar nada no aparelho."
        case .connecting:
            service.pin == nil ? "A imagem aparece em instantes." : "Digite este código no aparelho para autorizar."
        case .mirroring:
            ""
        case .failed(let message):
            message
        }
    }
}

// MARK: - Pieces

/// Phone symbol with radiating rings; the rings speed up while connecting.
struct Beacon: View {
    var phase: MirrorService.Phase
    var symbol: String

    var body: some View {
        TimelineView(.animation(paused: !animating)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            let period = phase == .connecting ? 1.2 : 2.6
            ZStack {
                ForEach(0..<3, id: \.self) { i in
                    let progress = ((t / period) + Double(i) / 3).truncatingRemainder(dividingBy: 1)
                    Circle()
                        .stroke(ringGradient, lineWidth: 1.5)
                        .scaleEffect(0.45 + progress * 0.55)
                        .opacity(animating ? (1 - progress) * 0.7 : 0)
                }
                Circle()
                    .fill(.clear)
                    .frame(width: 92, height: 92)
                    .glassEffect(.regular.tint(tint.opacity(0.25)), in: .circle)
                Image(systemName: symbol)
                    .font(.system(size: 40, weight: .regular))
                    .foregroundStyle(tint.gradient)
                    .symbolEffect(.bounce, value: phase == .connecting)
                    .contentTransition(.symbolEffect(.replace))
            }
        }
    }

    private var animating: Bool {
        phase == .ready || phase == .connecting || phase == .starting
    }

    private var tint: Color {
        if case .failed = phase { return .orange }
        return .accentColor
    }

    private var ringGradient: AngularGradient {
        AngularGradient(colors: [tint, tint.opacity(0.2), .purple.opacity(0.6), tint], center: .center)
    }
}

struct StatusPill: View {
    var phase: MirrorService.Phase
    var name: String
    @State private var pulse = false

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
                .shadow(color: color.opacity(0.8), radius: pulse ? 5 : 1)
                .animation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true), value: pulse)
            Text(text)
                .font(.system(size: 12, weight: .medium))
                .contentTransition(.opacity)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .glassEffect(.regular, in: .capsule)
        .onAppear { pulse = true }
    }

    private var color: Color {
        switch phase {
        case .ready, .mirroring: .green
        case .connecting: .blue
        case .starting: .yellow
        case .failed: .red
        }
    }

    private var text: String {
        switch phase {
        case .ready, .mirroring: "Visível na rede como “\(name)”"
        case .connecting: "Recebendo conexão"
        case .starting: "Iniciando"
        case .failed: "Receptor parado"
        }
    }
}

struct StepsCard: View {
    var name: String

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            step(1, "switch.2", "Abra a Central de Controle",
                 "Deslize do canto superior direito da tela para baixo.")
            divider
            step(2, "rectangle.on.rectangle", "Toque em Espelhar Tela",
                 "É o botão com dois retângulos.")
            divider
            step(3, "checkmark.circle", "Escolha “\(name)”",
                 "Pronto: a tela aparece nesta janela.")
        }
        .padding(.vertical, 20)
        .padding(.horizontal, 8)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: 640)
        .glassEffect(.regular, in: .rect(cornerRadius: 24))
    }

    private var divider: some View {
        Rectangle()
            .fill(.separator)
            .frame(width: 1)
            .padding(.vertical, 6)
    }

    private func step(_ number: Int, _ symbol: String, _ title: String, _ detail: String) -> some View {
        VStack(spacing: 10) {
            ZStack(alignment: .topTrailing) {
                Image(systemName: symbol)
                    .font(.system(size: 22, weight: .medium))
                    .foregroundStyle(.tint)
                    .frame(width: 50, height: 50)
                    .background(Circle().fill(.tint.opacity(0.12)))
                Text("\(number)")
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .frame(width: 18, height: 18)
                    .background(Circle().fill(.tint))
                    .offset(x: 4, y: -4)
            }
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .multilineTextAlignment(.center)
            Text(detail)
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 14)
        .frame(maxWidth: .infinity)
    }
}

struct PinCard: View {
    var pin: String

    var body: some View {
        VStack(spacing: 12) {
            Text("Código de acesso")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
            HStack(spacing: 10) {
                ForEach(Array(pin.enumerated()), id: \.offset) { _, digit in
                    Text(String(digit))
                        .font(.system(size: 40, weight: .bold, design: .rounded).monospacedDigit())
                        .frame(width: 58, height: 72)
                        .glassEffect(.regular.tint(.accentColor.opacity(0.15)), in: .rect(cornerRadius: 16))
                }
            }
            Text("Só é pedido na primeira vez em cada aparelho.")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
        }
        .padding(24)
        .glassEffect(.regular, in: .rect(cornerRadius: 28))
    }
}

/// Soft, slowly drifting colour field behind the glass.
struct AmbientBackground: View {
    var active: Bool
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30)) { context in
            let t = context.date.timeIntervalSinceReferenceDate * (active ? 0.5 : 0.18)
            MeshGradient(
                width: 3, height: 3,
                points: [
                    [0, 0], [0.5, 0], [1, 0],
                    [0, 0.5], [Float(0.5 + 0.18 * sin(t)), Float(0.5 + 0.14 * cos(t * 1.3))], [1, 0.5],
                    [0, 1], [0.5, 1], [1, 1],
                ],
                colors: colors(t)
            )
        }
        .opacity(scheme == .dark ? 0.55 : 0.35)
        .background(Color(nsColor: .windowBackgroundColor))
        .ignoresSafeArea()
    }

    private func colors(_ t: Double) -> [Color] {
        let a = Color.accentColor
        let base = Color(nsColor: .windowBackgroundColor)
        let s = (sin(t * 0.7) + 1) / 2
        return [
            a.opacity(0.55), base, .purple.opacity(0.45),
            base, a.opacity(0.25 + 0.2 * s), base,
            .cyan.opacity(0.35), base, a.opacity(0.4),
        ]
    }
}
