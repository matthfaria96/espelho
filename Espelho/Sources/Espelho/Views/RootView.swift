import SwiftUI

struct RootView: View {
    @EnvironmentObject private var service: MirrorService
    @StateObject private var windowController = WindowController()
    @AppStorage(Prefs.onboardingDone) private var onboardingDone = false
    @AppStorage(Prefs.keepOnTop) private var keepOnTop = false
    @AppStorage(Prefs.fitWindow) private var fitWindow = true

    var body: some View {
        ZStack {
            if service.phase == .mirroring {
                MirrorView(windowController: windowController)
                    .transition(.opacity.combined(with: .scale(scale: 0.98)))
            } else {
                WaitingView()
                    .transition(.opacity)
            }
        }
        .frame(minWidth: 360, minHeight: 360)
        .background(WindowReader { window in
            windowController.attach(window)
            windowController.setFloating(keepOnTop)
        })
        .overlay(alignment: .bottom) { ToastView() }
        .sheet(isPresented: $service.showOnboarding) {
            OnboardingView(start: service.tutorialPlatform) {
                onboardingDone = true
                service.showOnboarding = false
            }
        }
        .onAppear {
            if !onboardingDone || ProcessInfo.processInfo.environment["ESPELHO_TUTORIAL"] != nil { service.showOnboarding = true }
            if service.phase == .mirroring, fitWindow {
                // Window reopened from the menu bar in the middle of a session.
                DispatchQueue.main.async { windowController.fit(to: service.videoSize, force: true) }
            } else if fitWindow {
                // The saved frame may be a phone shape left over from a session that ended abruptly.
                DispatchQueue.main.async { windowController.restoreWelcomeSize() }
            }
        }
        .onChange(of: keepOnTop) { _, value in windowController.setFloating(value) }
        .onChange(of: service.videoSize) { _, size in
            if service.phase == .mirroring, fitWindow { windowController.fit(to: size) }
        }
        .onChange(of: service.phase) { old, new in
            if new == .mirroring {
                if service.showOnboarding {
                    // They followed the steps and it worked: the tour is done.
                    onboardingDone = true
                    service.showOnboarding = false
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
                        if fitWindow { windowController.fit(to: service.videoSize, force: true) }
                    }
                }
                if fitWindow { windowController.fit(to: service.videoSize, force: true) }
            } else if old == .mirroring {
                windowController.setTitlebarButtonsVisible(true)
                if windowController.isFullScreen {
                    windowController.toggleFullScreen()
                } else if fitWindow {
                    windowController.restoreWelcomeSize()
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .espelhoFitWindow)) { _ in
            windowController.fit(to: service.videoSize, force: true)
        }
    }
}

/// Small confirmation bubble ("Captura salva…").
struct ToastView: View {
    @EnvironmentObject private var service: MirrorService

    var body: some View {
        if let toast = service.toast {
            HStack(spacing: 10) {
                Image(systemName: toast.symbol)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.tint)
                Text(toast.text)
                    .font(.system(size: 13, weight: .medium))
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 440, alignment: .leading)
                if let url = toast.revealURL {
                    Button("Mostrar") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                        .buttonStyle(.borderless)
                        .font(.system(size: 13, weight: .semibold))
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .glassEffect(.regular, in: .rect(cornerRadius: toast.text.count > 60 ? 18 : 40))
            .padding(.horizontal, 16)
            .padding(.bottom, 84)
            .id(toast.id)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }
}
