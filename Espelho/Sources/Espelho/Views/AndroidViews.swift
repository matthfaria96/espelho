import SwiftUI

/// Android section of the welcome screen: devices found, or how to connect one.
struct AndroidCard: View {
    @EnvironmentObject private var service: MirrorService
    @ObservedObject var android = AndroidManager.shared

    var body: some View {
        Group {
            if !ADB.available {
                message("exclamationmark.triangle", "O componente para Android não está instalado.",
                        "Use Reparar no menu Ajuda ou reinstale o Espelho.")
            } else if android.devices.isEmpty && !android.knownIDs.isEmpty {
                searching
            } else if android.devices.isEmpty {
                empty
            } else {
                list
            }
        }
        .frame(maxWidth: 560)
        .glassEffect(.regular, in: .rect(cornerRadius: 24))
        .animation(.smooth, value: android.devices)
    }

    private var empty: some View {
        HStack(alignment: .top, spacing: 0) {
            option(symbol: "wifi", title: "Pelo Wi-Fi",
                   detail: "Android 11 ou mais novo. Você pareia uma vez lendo um QR code.") {
                Button("Conectar pelo Wi-Fi…") { android.beginPairing() }
                    .buttonStyle(.glassProminent)
            }
            Rectangle().fill(.separator).frame(width: 1).padding(.vertical, 6)
            option(symbol: "cable.connector", title: "Pelo cabo USB",
                   detail: "Qualquer Android. Ligue a Depuração USB nas Opções do desenvolvedor e conecte o cabo. Depois dá para passar para o Wi-Fi.") {
                EmptyView()
            }
        }
        .padding(.vertical, 20)
        .padding(.horizontal, 8)
        .fixedSize(horizontal: false, vertical: true)
    }

    /// Someone who already paired: the phone just needs Wireless debugging switched back on.
    private var searching: some View {
        VStack(spacing: 12) {
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text("Procurando seu Android…").font(.system(size: 14, weight: .semibold))
            }
            Text("No Android, ligue a **Depuração por Wi-Fi** (ela desliga sozinha quando o aparelho reinicia ou troca de rede). O Espelho conecta sozinho em seguida.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Label {
                Text("Dica: em Opções do desenvolvedor › **Blocos de desenvolvedor para configurações rápidas**, ative **Depuração por Wi-Fi**. Assim ela liga com um toque, direto da cortina de notificações.")
            } icon: {
                Image(systemName: "lightbulb").foregroundStyle(.yellow)
            }
            .font(.system(size: 11.5))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 14).fill(.quaternary.opacity(0.5)))
            HStack(spacing: 14) {
                Button("Parear outro Android") { android.beginPairing() }
                Text("·").foregroundStyle(.tertiary)
                Text("Ou conecte pelo cabo USB").foregroundStyle(.secondary)
            }
            .font(.system(size: 12))
            .buttonStyle(.borderless)
        }
        .padding(22)
    }

    private func option<Accessory: View>(symbol: String, title: LocalizedStringKey, detail: LocalizedStringKey,
                                         @ViewBuilder accessory: () -> Accessory) -> some View {
        VStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 22, weight: .medium))
                .foregroundStyle(.tint)
                .frame(width: 50, height: 50)
                .background(Circle().fill(.tint.opacity(0.12)))
            Text(title).font(.system(size: 13, weight: .semibold))
            Text(detail)
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            accessory()
        }
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity)
    }

    private var list: some View {
        VStack(spacing: 0) {
            ForEach(android.devices) { device in
                HStack(spacing: 12) {
                    Image(systemName: device.symbol)
                        .font(.system(size: 20, weight: .medium))
                        .foregroundStyle(.tint)
                        .frame(width: 40, height: 40)
                        .background(Circle().fill(.tint.opacity(0.12)))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(device.name).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                        Text(status(device))
                            .font(.system(size: 11.5))
                            .foregroundStyle(device.isReady ? AnyShapeStyle(.secondary) : AnyShapeStyle(.orange))
                    }
                    Spacer()
                    if device.isReady, !device.isWireless {
                        Button {
                            android.makeWireless(device)
                        } label: {
                            if android.goingWireless == device.serial {
                                ProgressView().controlSize(.small)
                            } else {
                                Label("Usar sem fio", systemImage: "wifi")
                            }
                        }
                        .buttonStyle(.glass)
                        .help("Depois disso dá para tirar o cabo (até o Android reiniciar). Funciona em qualquer versão do Android.")
                    }
                    if device.isReady {
                        Button("Espelhar") { service.startAndroid(device) }
                            .buttonStyle(.glassProminent)
                            .disabled(service.phase == .connecting)
                    }
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 10)
                if device.id != android.devices.last?.id { Divider().padding(.leading, 70) }
            }
            Divider()
            Button {
                android.beginPairing()
            } label: {
                Label("Parear outro Android pelo Wi-Fi", systemImage: "plus.circle")
                    .font(.system(size: 12, weight: .medium))
            }
            .buttonStyle(.borderless)
            .padding(.vertical, 10)
        }
        .padding(.top, 6)
    }

    private func status(_ device: AndroidManager.Device) -> String {
        switch device.state {
        case "device": device.isWireless ? String(localized: "Conectado pelo Wi-Fi") : String(localized: "Conectado pelo cabo")
        case "unauthorized": String(localized: "Toque em “Permitir” no aparelho")
        default: String(localized: "Aguardando o aparelho…")
        }
    }

    private func message(_ symbol: String, _ title: LocalizedStringKey, _ detail: LocalizedStringKey) -> some View {
        VStack(spacing: 8) {
            Image(systemName: symbol).font(.system(size: 24)).foregroundStyle(.orange)
            Text(title).font(.system(size: 13, weight: .semibold))
            Text(detail).font(.system(size: 11.5)).foregroundStyle(.secondary)
        }
        .padding(24)
        .frame(maxWidth: .infinity)
    }
}

/// One-time Wi-Fi pairing: the phone scans a QR code shown here (or types a code).
struct AndroidPairingView: View {
    @ObservedObject var android = AndroidManager.shared
    @State private var useCode = false
    @State private var code = ""

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 28) {
                VStack(alignment: .leading, spacing: 18) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Conectar um Android")
                            .font(.system(size: 24, weight: .bold, design: .rounded))
                        Text("Só na primeira vez. Depois, o Espelho reconhece o aparelho sozinho.")
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                    }
                    step(1, "Ative as Opções do desenvolvedor",
                         "Configurações › Sobre o telefone › Informações do software. Toque 7 vezes em “Número de compilação”.")
                    step(2, "Ligue a Depuração por Wi-Fi",
                         "Configurações › Opções do desenvolvedor › Depuração por Wi-Fi. Confirme em “Permitir”.")
                    step(3, useCode ? "Toque em Parear com código" : "Toque em Parear com QR code",
                         useCode ? "Digite ao lado os 6 números que aparecerem no Android."
                                 : "Dentro de Depuração por Wi-Fi. Aponte a câmera para o código ao lado.")
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                VStack(spacing: 14) {
                    if useCode { codeEntry } else { qrPanel }
                    statusLine
                    PairingTroubleHint()
                }
                .frame(width: 236)
            }
            .padding(28)

            Divider()
            HStack {
                Button(useCode ? "Usar QR code" : "Parear com código") {
                    withAnimation(.smooth) { useCode.toggle() }
                    if !useCode { android.beginPairing() } else { android.cancelPairing() }
                }
                .buttonStyle(.borderless)
                Spacer()
                Text("Android e Mac no mesmo Wi-Fi.")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                Spacer()
                Button("Cancelar") { android.closePairing() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
        }
        .frame(width: 640)
    }

    private var qrPanel: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 20).fill(.white)
            if case .waiting(let payload) = android.pairing, let image = AndroidManager.qrImage(payload) {
                Image(nsImage: image)
                    .interpolation(.none)
                    .resizable()
                    .padding(16)
                    .transition(.opacity)
            } else if case .failed = android.pairing {
                Image(systemName: "qrcode").font(.system(size: 80)).foregroundStyle(.black.opacity(0.12))
            } else {
                ProgressView().controlSize(.large)
            }
        }
        .frame(width: 220, height: 220)
        .shadow(color: .black.opacity(0.15), radius: 12, y: 4)
    }

    private var codeEntry: some View {
        VStack(spacing: 12) {
            TextField("000000", text: $code)
                .font(.system(size: 34, weight: .bold, design: .rounded).monospacedDigit())
                .multilineTextAlignment(.center)
                .textFieldStyle(.plain)
                .padding(.vertical, 14)
                .glassEffect(.regular, in: .rect(cornerRadius: 16))
                .onChange(of: code) { _, value in
                    let digits = String(value.filter(\.isNumber).prefix(6))
                    if digits != value { code = digits }
                }
                .onSubmit(submitCode)
            Button("Parear", action: submitCode)
                .buttonStyle(.glassProminent)
                .controlSize(.large)
                .disabled(code.count != 6 || android.pairing == .pairing || android.pairing == .connecting)
        }
        .frame(height: 220)
    }

    private func submitCode() {
        guard code.count == 6 else { return }
        android.pair(code: code)
    }

    @ViewBuilder private var statusLine: some View {
        switch android.pairing {
        case .idle, .waiting:
            Label(useCode ? "Digite o código do Android" : "Aguardando o Android ler o código…",
                  systemImage: "dot.radiowaves.left.and.right")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .symbolEffect(.variableColor.iterative, isActive: !useCode)
        case .pairing:
            Label("Pareando…", systemImage: "link").font(.system(size: 12, weight: .medium))
        case .connecting:
            Label("Conectando…", systemImage: "checkmark.circle").font(.system(size: 12, weight: .medium)).foregroundStyle(.green)
        case .failed(let message):
            VStack(spacing: 8) {
                Text(message)
                    .font(.system(size: 12))
                    .foregroundStyle(.orange)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Tentar de novo") {
                    if useCode { android.cancelPairing() } else { android.beginPairing() }
                }
                .buttonStyle(.glass)
            }
        }
    }

    private func step(_ number: Int, _ title: LocalizedStringKey, _ detail: LocalizedStringKey) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(number)")
                .font(.system(size: 12, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .frame(width: 24, height: 24)
                .background(Circle().fill(.tint))
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 13, weight: .semibold))
                Text(detail)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// Under the pairing code: what usually keeps a phone that scanned it from showing up.
struct PairingTroubleHint: View {
    @ObservedObject var android = AndroidManager.shared

    var body: some View {
        if android.localNetworkBlocked {
            hint("lock.shield", .orange,
                 "O macOS está bloqueando o Espelho na rede local. Ligue o Espelho em **Privacidade e Segurança › Rede Local**.")
        } else if android.pairingSlow && isWaiting {
            hint("questionmark.circle", .secondary,
                 "Leu o código e nada aconteceu? Confira se o Android e o Mac estão no mesmo Wi-Fi (rede de convidados não serve) e se o Espelho está ligado em **Privacidade e Segurança › Rede Local**.")
        }
    }

    private var isWaiting: Bool {
        if case .waiting = android.pairing { return true }
        return false
    }

    private func hint(_ symbol: String, _ color: Color, _ text: LocalizedStringKey) -> some View {
        VStack(spacing: 6) {
            Label {
                Text(text).fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: symbol).foregroundStyle(color)
            }
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            Button("Abrir Ajustes de Rede Local") { AndroidManager.openLocalNetworkSettings() }
                .buttonStyle(.link)
                .font(.system(size: 11, weight: .medium))
        }
        .transition(.opacity)
    }
}
