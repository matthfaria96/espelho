import ServiceManagement
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var service: MirrorService

    @AppStorage(Prefs.deviceName) private var deviceName = "Espelho"
    @AppStorage(Prefs.quality) private var quality = Prefs.Quality.standard.rawValue
    @AppStorage(Prefs.frameRate) private var frameRate = 60
    @AppStorage(Prefs.smooth) private var smooth = true
    @AppStorage(Prefs.audio) private var audio = true
    @AppStorage(Prefs.audioDelay) private var audioDelay = 0
    @AppStorage(Prefs.requirePin) private var requirePin = false
    @AppStorage(Prefs.keepOnTop) private var keepOnTop = false
    @AppStorage(Prefs.fitWindow) private var fitWindow = true
    @AppStorage(Prefs.menuBar) private var menuBar = true
    @AppStorage(Prefs.androidAutoConnect) private var androidAutoConnect = true
    @AppStorage(Prefs.androidScreenOff) private var androidScreenOff = false
    @State private var forgotAndroid = false
    @State private var language = AppLanguage.current
    @State private var languageChanged = false

    @State private var draftName = ""
    @State private var draftDelay = 0.0
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginError: String?

    var body: some View {
        Form {
            Section {
                TextField("Nome no Espelhar Tela", text: $draftName)
                    .onSubmit(commitName)
                Toggle("Pedir código na primeira conexão", isOn: $requirePin)
            } header: {
                Text("Conexão")
            } footer: {
                Text("O nome é o que aparece na lista do Espelhar Tela. Com o código ligado, cada aparelho novo precisa digitar um número de 4 dígitos mostrado aqui.")
            }

            Section {
                Picker("Prioridade", selection: $smooth) {
                    Text("Suavidade").tag(true)
                    Text("Resposta rápida").tag(false)
                }
                .pickerStyle(.segmented)
                Picker("Quadros por segundo", selection: $frameRate) {
                    Text("60").tag(60)
                    Text("30").tag(30)
                }
                .pickerStyle(.segmented)
                Picker("Qualidade", selection: $quality) {
                    ForEach(Prefs.Quality.allCases) { Text($0.title).tag($0.rawValue) }
                }
            } header: {
                Text("Fluidez e imagem")
            } footer: {
                Text(smooth
                     ? "Suavidade: os quadros saem no mesmo ritmo em que o aparelho os gerou, absorvendo as oscilações do Wi-Fi. Acrescenta poucos milissegundos, ajustados sozinhos conforme a rede."
                     : "Resposta rápida: cada quadro aparece no instante em que chega. É o menor atraso possível, mas pode engasgar se o Wi-Fi oscilar.")
            }

            Section {
                Toggle("Tocar o som do aparelho no Mac", isOn: $audio)
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Sincronia do som")
                        Spacer()
                        Text(delayLabel(Int(draftDelay)))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    Slider(value: $draftDelay, in: -300...300, step: 10) {
                        EmptyView()
                    } minimumValueLabel: {
                        Text("Antes").font(.caption)
                    } maximumValueLabel: {
                        Text("Depois").font(.caption)
                    } onEditingChanged: { editing in
                        if !editing { commitDelay() }
                    }
                    .disabled(!audio)
                    if Int(draftDelay) != 0 {
                        Button("Voltar ao automático") {
                            draftDelay = 0
                            commitDelay()
                        }
                        .buttonStyle(.link)
                        .font(.caption)
                    }
                }
            } header: {
                Text("Som")
            } footer: {
                Text("O som segue o relógio do aparelho, junto com a imagem. Se notar a boca fora de sincronia num vídeo, mova para “Depois” quando o som chegar antes da imagem, ou para “Antes” no caso contrário.")
            }

            Section {
                Toggle("Conectar sozinho aos Androids já pareados", isOn: $androidAutoConnect)
                Toggle("Apagar a tela do Android enquanto espelha", isOn: $androidScreenOff)
                LabeledContent("Aparelhos pareados") {
                    Button(forgotAndroid ? "Esquecidos" : "Esquecer todos") {
                        AndroidManager.shared.forgetAll()
                        forgotAndroid = true
                    }
                    .disabled(forgotAndroid || AndroidManager.shared.knownIDs.isEmpty)
                }
            } header: {
                Text("Android")
            } footer: {
                Text("Com a Depuração por Wi-Fi ligada no Android, o Espelho conecta assim que a janela estiver aberta. Apagar a tela economiza bateria: a imagem continua aqui e você controla pelo Mac. Qualidade, quadros por segundo e som acima valem também para o Android.")
            }

            Section {
                Toggle("Abrir o Espelho ao iniciar o Mac", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, enabled in setLaunchAtLogin(enabled) }
                Toggle("Ícone na barra de menus", isOn: $menuBar)
                Toggle("Manter a janela acima das outras", isOn: $keepOnTop)
                Toggle("Ajustar a janela ao formato do aparelho", isOn: $fitWindow)
            } header: {
                Text("Mac")
            } footer: {
                if let loginError {
                    Text(loginError).foregroundStyle(.red)
                } else {
                    Text("Com o ícone na barra de menus, fechar a janela deixa o Espelho pronto em segundo plano. A janela volta sozinha quando um aparelho se conecta.")
                }
            }

            Section {
                LabeledContent("Receptor AirPlay do macOS") {
                    Button("Abrir Ajustes…") {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.AirDrop-Handoff-Settings.extension")!)
                    }
                }
            } header: {
                Text("Lista do Espelhar Tela")
            } footer: {
                Text("O macOS tem um receptor próprio que também aparece na lista, com o nome deste Mac. Desligue-o em AirDrop e Handoff › Receptor AirPlay para ver só “\(deviceName)”.")
            }

            Section {
                Picker("Idioma", selection: $language) {
                    ForEach(AppLanguage.allCases) { Text($0.title).tag($0) }
                }
                .onChange(of: language) { _, value in
                    value.apply()
                    languageChanged = true
                }
                if languageChanged {
                    HStack {
                        Label("O novo idioma vale depois de reabrir o Espelho.", systemImage: "arrow.clockwise.circle")
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Reabrir Agora") { AppLanguage.relaunch() }
                    }
                }
            } header: {
                Text("Idioma")
            }

            Section {
                AboutRow()
            }
        }
        .formStyle(.grouped)
        .frame(width: 540)
        .frame(minHeight: 560, idealHeight: 760)
        .onAppear {
            draftName = deviceName
            draftDelay = Double(audioDelay)
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
        .onDisappear(perform: commitName)
        .onChange(of: quality) { service.applySettingsIfNeeded() }
        .onChange(of: frameRate) { service.applySettingsIfNeeded() }
        .onChange(of: audio) { service.applySettingsIfNeeded() }
        .onChange(of: requirePin) { service.applySettingsIfNeeded() }
        .onChange(of: smooth) { service.applySettingsIfNeeded() }
    }

    private func delayLabel(_ ms: Int) -> String {
        ms == 0 ? String(localized: "Automático") : (ms > 0 ? "+\(ms) ms" : "\(ms) ms")
    }

    private func commitName() {
        let trimmed = draftName.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = trimmed.isEmpty ? "Espelho" : String(trimmed.prefix(40))
        draftName = name
        guard name != deviceName else { return }
        deviceName = name
        service.applySettingsIfNeeded()
    }

    private func commitDelay() {
        let value = Int(draftDelay)
        guard value != audioDelay else { return }
        audioDelay = value
        service.applySettingsIfNeeded()
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            loginError = nil
        } catch {
            loginError = String(localized: "Não foi possível mudar: \(error.localizedDescription)")
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }
}

/// Settings › last section: version, links and updates, as in the other witchmymac apps.
private struct AboutRow: View {
    private var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return String(localized: "Versão \(short) (\(build))")
    }

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 12) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 48, height: 48)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Espelho").font(.system(size: 15, weight: .semibold))
                    Text(version).font(.system(size: 11.5)).foregroundStyle(.secondary).monospacedDigit()
                }
                Spacer()
                if AppUpdater.shared.isAvailable {
                    CheckForUpdatesButton().buttonStyle(.glass)
                }
            }
            HStack(spacing: 8) {
                Link(destination: URL(string: "https://witchmymac.com")!) {
                    Label("witchmymac.com", systemImage: "globe")
                }
                Link(destination: URL(string: "https://github.com/matthfaria96/espelho")!) {
                    Label("GitHub", systemImage: "chevron.left.forwardslash.chevron.right")
                }
                Spacer()
            }
            .buttonStyle(.glass)
            .controlSize(.small)
            Text("Software livre (GPL-3.0). Receptor AirPlay: UxPlay (GPL-3.0) com GStreamer (LGPL). Android: scrcpy (Apache 2.0). Atualizações: Sparkle (MIT).")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 4)
    }
}
