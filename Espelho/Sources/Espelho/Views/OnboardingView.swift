import SwiftUI

/// Step-by-step tutorial, one track for iPhone/iPad and one for Android, with animated
/// drawings of the phone screen. Shown on first launch, from “Como funciona” and the Help menu.
struct OnboardingView: View {
    enum Platform: String { case apple, android }

    var onFinish: () -> Void
    @State private var platform: Platform?
    @State private var step = 0
    @State private var forward = true
    @AppStorage(Prefs.welcomeTab) private var tab = "apple"

    init(start: Platform? = nil, onFinish: @escaping () -> Void) {
        self.onFinish = onFinish
        _platform = State(initialValue: start)
        // Diagnostics: ESPELHO_TUTORIAL=android:2 opens that step directly.
        if let spec = ProcessInfo.processInfo.environment["ESPELHO_TUTORIAL"] {
            let parts = spec.split(separator: ":")
            _platform = State(initialValue: Platform(rawValue: String(parts.first ?? "")))
            _step = State(initialValue: parts.count > 1 ? Int(parts[1]) ?? 0 : 0)
        }
    }

    private let stepCount = 5

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                content
                    .id("\(platform?.rawValue ?? "choose")-\(step)")
                    .transition(.asymmetric(
                        insertion: .move(edge: forward ? .trailing : .leading).combined(with: .opacity),
                        removal: .move(edge: forward ? .leading : .trailing).combined(with: .opacity)))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()

            footer
        }
        .frame(width: 720, height: 560)
        .animation(.spring(duration: 0.45, bounce: 0.15), value: step)
        .animation(.spring(duration: 0.45, bounce: 0.15), value: platform)
    }

    @ViewBuilder private var content: some View {
        switch platform {
        case nil: ChooserPage { choose($0) }
        case .apple?: AppleSteps(step: step)
        case .android?: AndroidSteps(step: step)
        }
    }

    private var footer: some View {
        HStack {
            if platform == nil {
                Button("Agora não", action: onFinish).buttonStyle(.glass)
            } else {
                Button("Voltar") { back() }.buttonStyle(.glass)
                Button {
                    forward = true
                    choose(platform == .apple ? .android : .apple)
                } label: {
                    Label(platform == .apple ? "Ver para Android" : "Ver para iPhone e iPad",
                          systemImage: "arrow.left.arrow.right")
                        .font(.system(size: 12, weight: .medium))
                }
                .buttonStyle(.borderless)
                .padding(.leading, 6)
            }
            Spacer()
            if platform != nil {
                HStack(spacing: 7) {
                    ForEach(0..<stepCount, id: \.self) { i in
                        Capsule()
                            .fill(i == step ? AnyShapeStyle(.tint) : AnyShapeStyle(.quaternary))
                            .frame(width: i == step ? 18 : 7, height: 7)
                    }
                }
            }
            Spacer()
            if platform != nil {
                Button(step == stepCount - 1 ? "Começar" : "Continuar") {
                    if step == stepCount - 1 { onFinish() } else { forward = true; step += 1 }
                }
                .buttonStyle(.glassProminent)
                .keyboardShortcut(.defaultAction)
            } else {
                Color.clear.frame(width: 90, height: 1)
            }
        }
        .controlSize(.large)
        .padding(.horizontal, 28)
        .padding(.bottom, 22)
        .padding(.top, 8)
    }

    private func choose(_ choice: Platform) {
        forward = true
        tab = choice.rawValue
        step = 0
        platform = choice
    }

    private func back() {
        forward = false
        if step > 0 { step -= 1 } else { platform = nil }
    }
}

// MARK: - Chooser

private struct ChooserPage: View {
    var choose: (OnboardingView.Platform) -> Void

    var body: some View {
        VStack(spacing: 0) {
            Image(systemName: "macbook.and.iphone")
                .font(.system(size: 40))
                .foregroundStyle(.tint)
                .symbolRenderingMode(.hierarchical)
                .frame(width: 92, height: 92)
                .glassEffect(.regular.tint(.accentColor.opacity(0.2)), in: .circle)
                .padding(.top, 34)
            Text("Bem-vindo ao Espelho")
                .font(.system(size: 28, weight: .bold, design: .rounded))
                .padding(.top, 16)
            Text("Veja a tela do seu celular ou tablet aqui no Mac, sem instalar nada no aparelho.\nQual aparelho você tem?")
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.top, 6)
            HStack(spacing: 18) {
                card(.apple, symbol: "iphone", title: "iPhone ou iPad",
                     detail: "Pelo Espelhar Tela da Central de Controle.", time: "Leva 10 segundos")
                card(.android, symbol: "smartphone", title: "Android",
                     detail: "Celulares e tablets. Dá para controlar pelo mouse e teclado do Mac.", time: "2 minutos, só na primeira vez")
            }
            .padding(.top, 28)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 32)
    }

    private func card(_ platform: OnboardingView.Platform, symbol: String, title: LocalizedStringKey, detail: LocalizedStringKey, time: LocalizedStringKey) -> some View {
        Button { choose(platform) } label: {
            VStack(spacing: 10) {
                Image(systemName: symbol)
                    .font(.system(size: 38, weight: .regular))
                    .foregroundStyle(.tint)
                    .frame(height: 50)
                Text(title).font(.system(size: 17, weight: .semibold))
                Text(detail)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                Label(time, systemImage: "clock")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.tertiary)
                    .padding(.top, 2)
            }
            .padding(22)
            .frame(width: 250, height: 210)
            .contentShape(.rect(cornerRadius: 26))
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 26))
    }
}

// MARK: - Step layout

private struct StepPage<Illustration: View, Text_: View>: View {
    var number: Int?
    var title: LocalizedStringKey
    @ViewBuilder var illustration: Illustration
    @ViewBuilder var text: Text_

    var body: some View {
        HStack(spacing: 34) {
            illustration
                .frame(width: 250, height: 440)
            VStack(alignment: .leading, spacing: 14) {
                if let number {
                    Text("PASSO \(number)")
                        .font(.system(size: 11, weight: .bold, design: .rounded))
                        .foregroundStyle(.tint)
                        .tracking(1)
                }
                Text(title)
                    .font(.system(size: 26, weight: .bold, design: .rounded))
                    .fixedSize(horizontal: false, vertical: true)
                text
                    .font(.system(size: 13.5))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 40)
        .padding(.top, 24)
    }
}

private struct Note: View {
    var symbol: String
    var color: Color = .accentColor
    var text: LocalizedStringKey

    var body: some View {
        Label {
            Text(text).fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: symbol).foregroundStyle(color)
        }
        .font(.system(size: 12))
        .foregroundStyle(.secondary)
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(.quaternary.opacity(0.45)))
    }
}

private struct Bullet: View {
    var symbol: String
    var text: LocalizedStringKey

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.tint)
                .frame(width: 28, height: 28)
                .background(Circle().fill(.tint.opacity(0.12)))
            Text(text)
                .font(.system(size: 13))
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 5)
        }
    }
}

// MARK: - iPhone / iPad track

private struct AppleSteps: View {
    var step: Int
    @AppStorage(Prefs.deviceName) private var deviceName = "Espelho"
    @AppStorage(Prefs.requirePin) private var requirePin = false

    private var name: String { deviceName.isEmpty ? "Espelho" : deviceName }

    var body: some View {
        switch step {
        case 0:
            StepPage(number: nil, title: "Tudo pronto para começar") {
                SameNetworkArt(phone: "iphone")
            } text: {
                Text("Você não precisa instalar nada no iPhone ou iPad. Só confira uma coisa:")
                Bullet(symbol: "wifi", text: "O aparelho e este Mac precisam estar **na mesma rede Wi-Fi**.")
                Bullet(symbol: "macwindow", text: "Deixe o Espelho aberto. Pode até fechar a janela: ele fica pronto no ícone da barra de menus.")
                Note(symbol: "info.circle.fill", text: "Se o Mac perguntar sobre **Rede Local**, clique em **Permitir**. É assim que o iPhone encontra este Mac.")
            }
        case 1:
            StepPage(number: 1, title: "Abra a Central de Controle") {
                PhoneMock { HomeScreenMock() }
            } text: {
                Text("No iPhone ou iPad, **deslize o dedo para baixo a partir do canto superior direito** da tela, onde ficam a bateria e o Wi-Fi.")
                Note(symbol: "hand.point.up.left", text: "Em iPhones com botão de Início (como o iPhone SE), deslize **de baixo para cima**.")
            }
        case 2:
            StepPage(number: 2, title: "Toque em Espelhar Tela") {
                PhoneMock(dark: true) { ControlCenterMock() }
            } text: {
                Text("Procure o botão com **dois retângulos sobrepostos** e toque nele.")
                Note(symbol: "questionmark.circle", text: "Não achou? Em **Ajustes › Central de Controle** dá para adicioná-lo. Em alguns aparelhos ele fica numa página que aparece deslizando a Central de Controle para o lado.")
            }
        case 3:
            StepPage(number: 3, title: "Escolha “\(name)”") {
                PhoneMock(dark: true) { MirrorListMock(name: name) }
            } text: {
                Text("Na lista que aparece, toque em **“\(name)”**. Em instantes a tela do aparelho aparece na janela do Espelho, com som.")
                if requirePin {
                    Note(symbol: "lock.fill", text: "Na primeira vez, o Mac mostra um **código de 4 números**: digite-o no aparelho.")
                }
                Note(symbol: "exclamationmark.bubble", text: "Também aparece o nome deste Mac na lista: é o receptor da própria Apple. Escolha sempre **“\(name)”**.")
            }
        default:
            StepPage(number: nil, title: "Pronto! Algumas dicas") {
                SameNetworkArt(phone: "iphone", connected: true)
            } text: {
                Bullet(symbol: "rotate.right", text: "Gire o aparelho e a janela acompanha.")
                Bullet(symbol: "arrow.up.left.and.arrow.down.right", text: "**Dois cliques** no vídeo deixam em tela cheia.")
                Bullet(symbol: "camera", text: "**⌘S** salva uma captura da tela do aparelho.")
                Bullet(symbol: "stop.circle", text: "Para parar: toque em **Parar Espelhamento** no aparelho, ou **⌘D** no Mac.")
            }
        }
    }
}

// MARK: - Android track

private struct AndroidSteps: View {
    var step: Int

    var body: some View {
        switch step {
        case 0:
            StepPage(number: nil, title: "Antes de começar") {
                SameNetworkArt(phone: "smartphone")
            } text: {
                Text("O Android não tem um botão de espelhar para Mac, então vamos ligar um recurso dele chamado **Depuração por Wi-Fi**. Leva uns 2 minutos e **só é preciso fazer uma vez**.")
                Bullet(symbol: "wifi", text: "Android e Mac **na mesma rede Wi-Fi**.")
                Bullet(symbol: "number", text: "**Android 11 ou mais novo.** Para ver: Configurações › Sobre o telefone.")
                Note(symbol: "cable.connector", text: "Android 10 ou mais antigo? Use o cabo USB: ligue a **Depuração USB** (passo 2), conecte o cabo e clique em **Usar sem fio** na aba Android.")
            }
        case 1:
            StepPage(number: 1, title: "Libere as Opções do desenvolvedor") {
                PhoneMock(android: true) { BuildNumberMock() }
            } text: {
                Text("Abra **Configurações** e encontre **Número de compilação**. Toque nele **7 vezes seguidas** até aparecer a mensagem de que o modo de desenvolvedor foi ativado. Se pedir, digite o PIN do aparelho.")
                VStack(alignment: .leading, spacing: 6) {
                    brand("Samsung", "Sobre o telefone › Informações do software › Número de compilação")
                    brand("Xiaomi, Redmi, POCO", "Sobre o telefone › Versão do HyperOS (ou do MIUI)")
                    brand("Motorola, Pixel e outros", "Sobre o telefone › Número da versão")
                }
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 12).fill(.quaternary.opacity(0.45)))
                Note(symbol: "checkmark.shield", text: "É seguro: isso só mostra um menu escondido. Nada muda no aparelho.")
            }
        case 2:
            StepPage(number: 2, title: "Ligue a Depuração por Wi-Fi") {
                PhoneMock(android: true) { DeveloperOptionsMock() }
            } text: {
                Text("Em **Configurações**, abra **Opções do desenvolvedor** (geralmente no fim da lista; na Xiaomi fica em *Configurações adicionais*). Ligue **Depuração por Wi-Fi** e toque em **Permitir**.")
                Note(symbol: "exclamationmark.triangle.fill", color: .orange, text: "**Xiaomi, Redmi e POCO:** ligue também **Depuração USB (configurações de segurança)**. Sem isso a imagem aparece, mas o Mac não consegue tocar na tela.")
            }
        case 3:
            StepPage(number: 3, title: "Leia o código com o Android") {
                LivePairingArt()
            } text: {
                Text("No Android, toque no **nome** “Depuração por Wi-Fi” (não no botão) para abrir a tela dela. Depois toque em **Parear dispositivo com QR code** e aponte a câmera para o código ao lado.")
                Text("Quando ler, o Espelho conecta sozinho e a tela do Android aparece.")
                    .foregroundStyle(.secondary)
                Note(symbol: "camera.metering.unknown", text: "Não leu? Na aba **Android** da tela inicial há a opção **Parear com código** (6 números).")
            }
        default:
            StepPage(number: nil, title: "Pronto! Como usar") {
                SameNetworkArt(phone: "smartphone", connected: true)
            } text: {
                Bullet(symbol: "cursorarrow.click", text: "**Clique** para tocar, **arraste** para deslizar, **role** no trackpad para rolar.")
                Bullet(symbol: "keyboard", text: "**Digite** no teclado do Mac. **⌘V** cola o que você copiou no Mac. **esc** volta.")
                Bullet(symbol: "arrow.clockwise", text: "Das próximas vezes, é só **ligar a Depuração por Wi-Fi**: o Espelho conecta sozinho. Ela desliga quando o Android reinicia.")
                Note(symbol: "lightbulb.fill", color: .yellow, text: "Para ligar com um toque: Opções do desenvolvedor › **Blocos de desenvolvedor para configurações rápidas** › ative **Depuração por Wi-Fi**. Ela aparece na cortina de notificações.")
            }
        }
    }

    private func brand(_ name: LocalizedStringKey, _ path: LocalizedStringKey) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(name).font(.system(size: 12, weight: .semibold))
            Text(path).font(.system(size: 11.5)).foregroundStyle(.secondary)
        }
    }
}

/// The real QR code, live: pairing happens right here in the tutorial.
private struct LivePairingArt: View {
    @ObservedObject private var android = AndroidManager.shared

    var body: some View {
        VStack(spacing: 16) {
            ZStack {
                RoundedRectangle(cornerRadius: 22).fill(.white)
                if case .waiting(let payload) = android.pairing, let image = AndroidManager.qrImage(payload) {
                    Image(nsImage: image).interpolation(.none).resizable().padding(16)
                } else if case .failed = android.pairing {
                    Image(systemName: "qrcode").font(.system(size: 90)).foregroundStyle(.black.opacity(0.12))
                } else {
                    ProgressView().controlSize(.large)
                }
            }
            .frame(width: 230, height: 230)
            .shadow(color: .black.opacity(0.18), radius: 14, y: 5)

            Group {
                switch android.pairing {
                case .idle, .waiting:
                    Label("Aguardando o Android…", systemImage: "dot.radiowaves.left.and.right")
                        .symbolEffect(.variableColor.iterative)
                        .foregroundStyle(.secondary)
                case .pairing:
                    Label("Pareando…", systemImage: "link")
                case .connecting:
                    Label("Conectando…", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                case .failed(let message):
                    VStack(spacing: 8) {
                        Text(message).foregroundStyle(.orange).multilineTextAlignment(.center)
                        Button("Gerar novo código") { android.beginPairing(showSheet: false) }
                            .buttonStyle(.glass)
                    }
                }
            }
            .font(.system(size: 12, weight: .medium))
            .frame(minHeight: 60, alignment: .top)

            PairingTroubleHint()
        }
        .onAppear { android.beginPairing(showSheet: false) }
        .onDisappear { android.cancelPairing() }
    }
}

// MARK: - Illustrations

/// Mac and phone side by side, with Wi-Fi waves (or a check when connected).
private struct SameNetworkArt: View {
    var phone: String
    var connected = false

    var body: some View {
        TimelineView(.animation) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            VStack(spacing: 18) {
                Image(systemName: connected ? "checkmark.circle.fill" : "wifi")
                    .font(.system(size: 34, weight: .semibold))
                    .foregroundStyle(connected ? AnyShapeStyle(.green) : AnyShapeStyle(.tint))
                    .opacity(connected ? 1 : 0.55 + 0.45 * abs(sin(t * 1.6)))
                HStack(alignment: .bottom, spacing: 18) {
                    Image(systemName: phone)
                        .font(.system(size: 64, weight: .light))
                    Image(systemName: "arrow.right")
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(.tint)
                        .offset(x: CGFloat(sin(t * 2.4)) * 4)
                        .padding(.bottom, 24)
                    Image(systemName: "macbook")
                        .font(.system(size: 92, weight: .light))
                }
                .foregroundStyle(.primary.opacity(0.85))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Circle().fill(.tint.opacity(0.08)).frame(width: 250, height: 250))
        }
    }
}

/// A phone outline holding a drawn screen.
private struct PhoneMock<Screen: View>: View {
    var android = false
    var dark = false
    @ViewBuilder var screen: Screen

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 36, style: .continuous)
                .fill(Color(white: 0.08))
                .shadow(color: .black.opacity(0.3), radius: 18, y: 8)
            screen
                .environment(\.colorScheme, dark ? .dark : .light)
                .frame(width: 196, height: 416)
                .clipShape(RoundedRectangle(cornerRadius: 29, style: .continuous))
            VStack {
                if android {
                    Circle().fill(.black).frame(width: 11, height: 11).padding(.top, 15)
                } else {
                    Capsule().fill(.black).frame(width: 62, height: 18).padding(.top, 13)
                }
                Spacer()
            }
        }
        .frame(width: 210, height: 430)
    }
}

/// A fingertip that taps (pressed = darker, with a ripple).
private struct Finger: View {
    var pressed: Bool

    var body: some View {
        ZStack {
            Circle()
                .stroke(.white.opacity(pressed ? 0.7 : 0), lineWidth: 2)
                .frame(width: pressed ? 46 : 26, height: pressed ? 46 : 26)
            Circle()
                .fill(.white.opacity(pressed ? 0.95 : 0.75))
                .frame(width: 26, height: 26)
                .overlay(Circle().stroke(.black.opacity(0.25), lineWidth: 1))
                .shadow(color: .black.opacity(0.35), radius: 4, y: 2)
        }
        .animation(.easeOut(duration: 0.18), value: pressed)
    }
}

private func loop(_ date: Date, period: Double) -> Double {
    date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: period)
}

private struct HomeScreenMock: View {
    private let colors: [Color] = [.green, .blue, .orange, .pink, .yellow, .purple, .teal, .red, .indigo, .mint, .cyan, .brown]

    var body: some View {
        TimelineView(.animation) { context in
            let t = loop(context.date, period: 2.6)
            let swipe = min(max((t - 0.5) / 1.0, 0), 1)
            ZStack(alignment: .topLeading) {
                LinearGradient(colors: [.indigo, .purple, .pink.opacity(0.8)], startPoint: .top, endPoint: .bottom)
                HStack {
                    Text("9:41").font(.system(size: 11, weight: .semibold))
                    Spacer()
                    HStack(spacing: 3) {
                        Image(systemName: "wifi")
                        Image(systemName: "battery.75percent")
                    }
                    .font(.system(size: 9))
                    .padding(4)
                    .background(Capsule().stroke(.white.opacity(t > 0.3 && t < 1.6 ? 0.9 : 0), lineWidth: 1.5))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 16)
                .padding(.top, 14)
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(34), spacing: 12), count: 4), spacing: 16) {
                    ForEach(0..<16, id: \.self) { i in
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .fill(colors[i % colors.count].gradient)
                            .frame(width: 34, height: 34)
                    }
                }
                .padding(.top, 60)
                .padding(.horizontal, 18)
                // Control Center sliding down with the finger.
                Rectangle()
                    .fill(.black.opacity(0.55))
                    .frame(height: 416 * swipe)
                Finger(pressed: t > 0.35 && t < 1.6)
                    .position(x: 165, y: 24 + 230 * swipe)
                    .opacity(t < 1.9 ? 1 : 0)
            }
        }
    }
}

private struct ControlCenterMock: View {
    var body: some View {
        TimelineView(.animation) { context in
            let t = loop(context.date, period: 2.2)
            let tapping = t > 1.0 && t < 1.35
            ZStack {
                LinearGradient(colors: [Color(white: 0.18), Color(white: 0.08)], startPoint: .top, endPoint: .bottom)
                VStack(spacing: 12) {
                    HStack(spacing: 12) {
                        tileGrid
                        RoundedRectangle(cornerRadius: 18).fill(.white.opacity(0.14))
                            .overlay(Image(systemName: "music.note").foregroundStyle(.white.opacity(0.6)))
                            .frame(width: 76, height: 76)
                    }
                    HStack(spacing: 12) {
                        roundTile("lock.rotation")
                        roundTile("moon.fill")
                        ZStack {
                            RoundedRectangle(cornerRadius: 18)
                                .fill(tapping ? Color.accentColor : Color.white.opacity(0.14))
                            Image(systemName: "rectangle.on.rectangle")
                                .font(.system(size: 20, weight: .semibold))
                                .foregroundStyle(.white)
                            RoundedRectangle(cornerRadius: 18)
                                .stroke(Color.accentColor, lineWidth: 2.5)
                                .scaleEffect(1 + 0.12 * abs(sin(t * 2.8)))
                                .opacity(tapping ? 0 : 0.9)
                        }
                        .frame(width: 76, height: 34)
                    }
                    HStack(spacing: 12) {
                        RoundedRectangle(cornerRadius: 18).fill(.white.opacity(0.14)).frame(width: 34, height: 76)
                        RoundedRectangle(cornerRadius: 18).fill(.white.opacity(0.14)).frame(width: 34, height: 76)
                        roundTile("flashlight.on.fill")
                        roundTile("camera.fill")
                    }
                    Spacer()
                }
                .padding(.top, 50)
                Finger(pressed: tapping)
                    .position(x: 140 - 40 * max(0, 1 - t), y: 178 + 30 * max(0, 1 - t))
            }
        }
    }

    private var tileGrid: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) { dot("airplane", .orange); dot("antenna.radiowaves.left.and.right", .green) }
            HStack(spacing: 8) { dot("wifi", .blue); dot("bolt.horizontal", .blue) }
        }
        .padding(6)
        .background(RoundedRectangle(cornerRadius: 18).fill(.white.opacity(0.14)))
    }

    private func dot(_ symbol: String, _ color: Color) -> some View {
        Circle().fill(color).frame(width: 28, height: 28)
            .overlay(Image(systemName: symbol).font(.system(size: 12, weight: .semibold)).foregroundStyle(.white))
    }

    private func roundTile(_ symbol: String) -> some View {
        Circle().fill(.white.opacity(0.14)).frame(width: 34, height: 34)
            .overlay(Image(systemName: symbol).font(.system(size: 13)).foregroundStyle(.white.opacity(0.8)))
    }
}

private struct MirrorListMock: View {
    var name: String

    var body: some View {
        TimelineView(.animation) { context in
            let t = loop(context.date, period: 2.8)
            let tapped = t > 1.2
            ZStack {
                LinearGradient(colors: [Color(white: 0.2), Color(white: 0.06)], startPoint: .top, endPoint: .bottom)
                VStack(alignment: .leading, spacing: 0) {
                    HStack {
                        Image(systemName: "rectangle.on.rectangle")
                        Text("Espelhar Tela").font(.system(size: 13, weight: .semibold))
                    }
                    .foregroundStyle(.white)
                    .padding(14)
                    Divider().overlay(.white.opacity(0.2))
                    row(symbol: "macwindow", title: "\(name)", highlight: true, checked: tapped)
                    Divider().overlay(.white.opacity(0.2)).padding(.leading, 44)
                    row(symbol: "macbook", title: "Mac de casa", highlight: false, checked: false)
                    Divider().overlay(.white.opacity(0.2)).padding(.leading, 44)
                    row(symbol: "tv", title: "TV da Sala", highlight: false, checked: false)
                }
                .background(RoundedRectangle(cornerRadius: 18).fill(.white.opacity(0.12)))
                .padding(.horizontal, 14)
                Finger(pressed: t > 1.0 && t < 1.3)
                    .position(x: 110, y: 186 + 40 * max(0, 1 - t))
                    .opacity(t < 2.0 ? 1 : 0)
            }
        }
    }

    private func row(symbol: String, title: LocalizedStringKey, highlight: Bool, checked: Bool) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol).frame(width: 20)
            Text(title).font(.system(size: 13, weight: highlight ? .semibold : .regular)).lineLimit(1)
            Spacer()
            if checked { Image(systemName: "checkmark").foregroundStyle(Color.accentColor) }
        }
        .foregroundStyle(.white.opacity(highlight ? 1 : 0.55))
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(highlight ? Color.accentColor.opacity(0.18) : .clear)
    }
}

/// Android-style settings screen (light).
private struct SettingsScreen<Content: View>: View {
    var title: LocalizedStringKey
    @ViewBuilder var content: Content

    var body: some View {
        ZStack(alignment: .top) {
            Color(white: 0.96)
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Image(systemName: "arrow.left")
                    Spacer()
                }
                .font(.system(size: 12, weight: .semibold))
                .padding(.top, 34)
                Text(title)
                    .font(.system(size: 19, weight: .semibold))
                    .padding(.top, 6)
                    .padding(.bottom, 8)
                content
            }
            .foregroundStyle(.black.opacity(0.85))
            .padding(.horizontal, 14)
        }
    }
}

private struct SettingsRow: View {
    var title: LocalizedStringKey
    var detail: LocalizedStringKey?
    var highlight = false
    var toggle: Bool?

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 12.5, weight: highlight ? .semibold : .regular))
                if let detail { Text(detail).font(.system(size: 10.5)).foregroundStyle(.black.opacity(0.5)) }
            }
            Spacer()
            if let toggle {
                Capsule()
                    .fill(toggle ? Color.accentColor : Color(white: 0.75))
                    .frame(width: 34, height: 20)
                    .overlay(alignment: toggle ? .trailing : .leading) {
                        Circle().fill(.white).frame(width: 16, height: 16).padding(2)
                    }
                    .animation(.spring(duration: 0.3), value: toggle)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 14).fill(highlight ? Color.accentColor.opacity(0.14) : .white))
    }
}

private struct BuildNumberMock: View {
    var body: some View {
        TimelineView(.animation) { context in
            let t = loop(context.date, period: 4.6)
            let taps = min(max(Int((t - 0.4) / 0.32) + 1, 0), 7)
            let pressed = t > 0.4 && t < 0.4 + 7 * 0.32 && (t - 0.4).truncatingRemainder(dividingBy: 0.32) < 0.14
            ZStack {
                SettingsScreen(title: "Informações do software") {
                    SettingsRow(title: "Versão do Android", detail: "15")
                    SettingsRow(title: "Versão da interface", detail: "7.0")
                    SettingsRow(title: "Número de compilação", detail: "AP3A.240905.015", highlight: true)
                    SettingsRow(title: "Status do Knox", detail: nil)
                }
                Finger(pressed: pressed)
                    .position(x: 98, y: 213)
                    .opacity(t < 3.0 ? 1 : 0)
                if taps > 0 && t < 3.0 {
                    Text(taps < 7 ? "\(taps)" : "7 ✓")
                        .font(.system(size: 13, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Capsule().fill(Color.accentColor))
                        .position(x: 150, y: 168)
                        .contentTransition(.numericText())
                }
                if t > 2.8 {
                    Text("O modo de desenvolvedor foi ativado.")
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(Capsule().fill(Color(white: 0.2)))
                        .position(x: 98, y: 360)
                        .transition(.opacity)
                }
            }
        }
    }
}

private struct DeveloperOptionsMock: View {
    var body: some View {
        TimelineView(.animation) { context in
            let t = loop(context.date, period: 4.2)
            let on = t > 0.9
            let dialog = t > 1.5 && t < 3.3
            ZStack {
                SettingsScreen(title: "Opções do desenvolvedor") {
                    SettingsRow(title: "Depuração USB", detail: "Para o cabo", toggle: false)
                    SettingsRow(title: "Depuração por Wi-Fi", detail: on ? "Ativado" : "Desativado", highlight: true, toggle: on && !dialog ? true : (t > 3.3))
                    SettingsRow(title: "Revogar autorizações", detail: nil)
                }
                if dialog {
                    Color.black.opacity(0.35)
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Permitir depuração por Wi-Fi nesta rede?")
                            .font(.system(size: 12.5, weight: .semibold))
                        Text("Rede: Casa").font(.system(size: 10.5)).foregroundStyle(.black.opacity(0.55))
                        HStack {
                            Spacer()
                            Text("Cancelar").font(.system(size: 11.5)).foregroundStyle(.black.opacity(0.55))
                            Text("Permitir")
                                .font(.system(size: 11.5, weight: .semibold))
                                .foregroundStyle(Color.accentColor)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(Capsule().fill(Color.accentColor.opacity(t > 2.6 ? 0.2 : 0)))
                        }
                    }
                    .foregroundStyle(.black.opacity(0.85))
                    .padding(16)
                    .background(RoundedRectangle(cornerRadius: 18).fill(.white))
                    .padding(.horizontal, 14)
                }
                Finger(pressed: (t > 0.7 && t < 0.95) || (t > 2.5 && t < 2.8))
                    .position(x: t < 1.5 ? 168 : 158, y: t < 1.5 ? 166 : 246)
                    .opacity(t < 3.3 ? 1 : 0)
            }
            .animation(.smooth(duration: 0.25), value: dialog)
        }
    }
}
