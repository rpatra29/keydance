import AppKit
import SwiftUI

struct OnboardingView: View {
    @EnvironmentObject private var state: AppState
    @State private var currentPage = 0
    @State private var isAdvancing = false
    @State private var introLogoExpanded = false
    @State private var introLogoAtTop = false
    @State private var introFinished = false
    @State private var introTransitioning = false

    private let totalPages = 4

    var body: some View {
        ZStack {
            OnboardingBackground()

            VStack(spacing: 0) {
                header

                ZStack {
                    switch currentPage {
                    case 0:
                        WelcomePage(isTransitioning: introTransitioning)
                            .transition(pageTransition)
                    case 1:
                        PermissionsPage()
                            .transition(pageTransition)
                    case 2:
                        FeaturePage()
                            .transition(pageTransition)
                    default:
                        GetStartedPage()
                            .transition(pageTransition)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .animation(.spring(response: 0.55, dampingFraction: 0.82), value: currentPage)

                bottomControls
            }
            .padding(.horizontal, 42)
            .padding(.vertical, 28)

            if currentPage == 0 && !introFinished {
                introLogoOverlay
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var header: some View {
        HStack {
            HStack(spacing: 9) {
                KeydanceLogo(width: 28)
                Text("keydance")
                    .font(.system(size: 16, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.9))
            }

            Spacer()

            Text("Step \(currentPage + 1) of \(totalPages)")
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(0.45))
        }
        .opacity(currentPage == 0 ? (introFinished ? 1 : 0) : 1)
        .frame(height: 30)
        .animation(.easeInOut(duration: 0.25), value: currentPage)
        .animation(.easeInOut(duration: 0.25), value: introFinished)
    }

    private var bottomControls: some View {
        VStack(spacing: 22) {
            HStack(spacing: 7) {
                ForEach(0..<totalPages, id: \.self) { index in
                    Capsule()
                        .fill(index == currentPage ? Color.white : Color.white.opacity(0.25))
                        .frame(width: index == currentPage ? 30 : 7, height: 7)
                        .animation(.spring(response: 0.3), value: currentPage)
                }
            }

            HStack(spacing: 14) {
                Button(action: goBack) {
                    Image(systemName: "arrow.left")
                        .font(.system(size: 17, weight: .medium))
                        .foregroundStyle(.white.opacity(currentPage > 0 ? 0.9 : 0.25))
                        .frame(width: 48, height: 48)
                        .background(Circle().fill(.white.opacity(0.1)))
                        .overlay(Circle().strokeBorder(.white.opacity(0.18), lineWidth: 1))
                }
                .buttonStyle(.plain)
                .disabled(currentPage == 0 || isAdvancing)

                Button(action: goForward) {
                    HStack(spacing: 9) {
                        Text(currentPage == totalPages - 1 ? "Start dancing" : "Continue")
                            .font(.system(size: 15, weight: .semibold, design: .rounded))
                        Image(systemName: currentPage == totalPages - 1 ? "checkmark" : "arrow.right")
                            .font(.system(size: 15, weight: .semibold))
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 23)
                    .frame(height: 48)
                    .background(
                        Capsule()
                            .fill(.white.opacity(0.16))
                            .overlay(Capsule().strokeBorder(.white.opacity(0.28), lineWidth: 1))
                    )
                    .shadow(color: .white.opacity(0.12), radius: 16)
                }
                .buttonStyle(.plain)
                .disabled(isAdvancing)
            }
        }
        .opacity(introTransitioning ? 0 : 1)
        .allowsHitTesting(!introTransitioning)
        .animation(.easeOut(duration: 0.18), value: introTransitioning)
    }

    private var introLogoOverlay: some View {
        GeometryReader { proxy in
            KeydanceLogo(width: introLogoAtTop ? 28 : (introLogoExpanded ? 520 : 208))
                .position(
                    x: introLogoAtTop ? 42 + 14 : proxy.size.width / 2,
                    y: introLogoAtTop
                        ? 28 + 15
                        : (introLogoExpanded ? proxy.size.height * 0.48 : proxy.size.height * 0.29)
                )
                .animation(.spring(response: 0.8, dampingFraction: 0.78), value: introLogoAtTop)
                .animation(.spring(response: 0.6, dampingFraction: 0.72), value: introLogoExpanded)
        }
        .allowsHitTesting(false)
        .transition(.opacity)
    }

    private var pageTransition: AnyTransition {
        .asymmetric(
            insertion: .move(edge: .trailing).combined(with: .opacity),
            removal: .move(edge: .leading).combined(with: .opacity)
        )
    }

    private func goBack() {
        guard currentPage > 0 else { return }
        withAnimation(.spring(response: 0.45, dampingFraction: 0.82)) {
            currentPage -= 1
            if currentPage == 0 {
                introLogoExpanded = false
                introLogoAtTop = false
                introFinished = false
                introTransitioning = false
            }
        }
    }

    private func goForward() {
        guard !isAdvancing else { return }

        if currentPage == totalPages - 1 {
            isAdvancing = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.65) {
                state.completeOnboarding()
            }
            return
        }

        isAdvancing = true
        if currentPage == 0 {
            withAnimation(.easeOut(duration: 0.18)) {
                introTransitioning = true
            }
            withAnimation(.spring(response: 0.6, dampingFraction: 0.72)) {
                introLogoExpanded = true
            }

            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                withAnimation(.spring(response: 0.8, dampingFraction: 0.78)) {
                    introLogoAtTop = true
                    introLogoExpanded = false
                }
            }

            DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) {
                withAnimation(.spring(response: 0.55, dampingFraction: 0.82)) {
                    currentPage += 1
                    introFinished = true
                    introTransitioning = false
                    isAdvancing = false
                }
            }
        } else {
            withAnimation(.spring(response: 0.55, dampingFraction: 0.82)) {
                currentPage += 1
                isAdvancing = false
            }
        }
    }
}

private struct OnboardingBackground: View {
    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color.black,
                    Color(red: 0.035, green: 0.045, blue: 0.075),
                    Color(red: 0.015, green: 0.018, blue: 0.03)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            Circle()
                .fill(Color.blue.opacity(0.12))
                .frame(width: 420, height: 420)
                .blur(radius: 90)
                .offset(x: -350, y: -280)

            Circle()
                .fill(Color.purple.opacity(0.1))
                .frame(width: 380, height: 380)
                .blur(radius: 100)
                .offset(x: 360, y: 280)
        }
        .ignoresSafeArea()
    }
}

private struct KeydanceLogo: View {
    let width: CGFloat

    var body: some View {
        logoImage
            .resizable()
            .scaledToFit()
            .frame(width: width)
            .shadow(color: .black.opacity(0.28), radius: width > 80 ? 16 : 4, y: width > 80 ? 8 : 2)
    }

    private var logoImage: Image {
        if let url = Bundle.main.url(forResource: "keydance", withExtension: "png"),
           let image = NSImage(contentsOf: url) {
            return Image(nsImage: image)
        }

        if let url = Bundle.module.url(forResource: "keydance", withExtension: "png"),
           let image = NSImage(contentsOf: url) {
            return Image(nsImage: image)
        }

        return Image(systemName: "keyboard.fill")
    }
}

private struct WelcomePage: View {
    let isTransitioning: Bool
    @State private var appeared = false

    var body: some View {
        VStack(spacing: 25) {
            Spacer(minLength: 10)

            VStack(spacing: 18) {
                Color.clear
                    .frame(width: 208, height: 160)

                VStack(spacing: 10) {
                    Text("Ready to dance?")
                        .font(.system(size: 44, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white)

                    Text("Type with style, flow with rhythm")
                        .font(.system(size: 18, weight: .regular, design: .rounded))
                        .foregroundStyle(.white.opacity(0.58))
                }
                .opacity(appeared ? 1 : 0)
                .offset(y: appeared ? 0 : 18)
            }

            Text("Keydance measures your flow without saving what you type.")
                .font(.system(size: 13, weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(0.38))
                .opacity(appeared ? 1 : 0)

            Spacer(minLength: 10)
        }
        .onAppear {
            withAnimation(.spring(response: 0.7, dampingFraction: 0.75).delay(0.15)) {
                appeared = true
            }
        }
        .opacity(isTransitioning ? 0 : 1)
        .animation(.easeOut(duration: 0.18), value: isTransitioning)
    }
}

private struct PermissionsPage: View {
    @EnvironmentObject private var state: AppState
    @State private var appeared = false

    var body: some View {
        VStack(spacing: 25) {
            Spacer(minLength: 10)

            OnboardingIcon(
                systemName: state.permissionGranted ? "checkmark.circle.fill" : "keyboard.badge.eye",
                tint: state.permissionGranted ? .green : .white
            )
            .scaleEffect(appeared ? 1 : 0.6)
            .opacity(appeared ? 1 : 0)

            VStack(spacing: 13) {
                Text(state.permissionGranted ? "You're all set" : "Input monitoring required")
                    .font(.system(size: 34, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)

                Text(state.permissionGranted
                     ? "Keydance can now measure your typing rhythm."
                     : "Keydance needs permission to detect timing and calculate your WPM.\n\nWe never record what you type — only timing data.")
                    .font(.system(size: 16, weight: .regular, design: .rounded))
                    .foregroundStyle(.white.opacity(0.62))
                    .multilineTextAlignment(.center)
                    .lineSpacing(5)
            }
            .opacity(appeared ? 1 : 0)
            .offset(y: appeared ? 0 : 18)

            if !state.permissionGranted {
                Button {
                    state.requestPermission()
                } label: {
                    Label("Grant permission", systemImage: "hand.raised.fill")
                        .font(.system(size: 16, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 26)
                        .frame(height: 46)
                        .background(
                            Capsule()
                                .fill(.white.opacity(0.14))
                                .overlay(Capsule().strokeBorder(.white.opacity(0.25), lineWidth: 1))
                        )
                }
                .buttonStyle(.plain)
                .opacity(appeared ? 1 : 0)
                .scaleEffect(appeared ? 1 : 0.9)
            } else {
                Label("Timing data stays on this Mac", systemImage: "lock.fill")
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .foregroundStyle(.green.opacity(0.9))
            }

            Spacer(minLength: 10)
        }
        .onAppear {
            withAnimation(.spring(response: 0.65, dampingFraction: 0.75).delay(0.15)) {
                appeared = true
            }
        }
    }
}

private struct FeaturePage: View {
    @State private var appeared = false

    var body: some View {
        VStack(spacing: 24) {
            Spacer(minLength: 10)

            OnboardingIcon(systemName: "chart.line.uptrend.xyaxis", tint: .white)
                .scaleEffect(appeared ? 1 : 0.6)
                .opacity(appeared ? 1 : 0)

            VStack(spacing: 12) {
                Text("Track your progress")
                    .font(.system(size: 34, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)

                Text("See your typing speed improve over time\nwith focused analytics and insights.")
                    .font(.system(size: 17, weight: .regular, design: .rounded))
                    .foregroundStyle(.white.opacity(0.62))
                    .multilineTextAlignment(.center)
                    .lineSpacing(5)
            }
            .opacity(appeared ? 1 : 0)
            .offset(y: appeared ? 0 : 18)

            ProgressPreview()
                .opacity(appeared ? 1 : 0)
                .offset(y: appeared ? 0 : 24)

            Spacer(minLength: 10)
        }
        .onAppear {
            withAnimation(.spring(response: 0.65, dampingFraction: 0.75).delay(0.12)) {
                appeared = true
            }
        }
    }
}

private struct GetStartedPage: View {
    @State private var appeared = false

    var body: some View {
        VStack(spacing: 24) {
            Spacer(minLength: 10)

            OnboardingIcon(systemName: "keyboard", tint: .white)
                .scaleEffect(appeared ? 1 : 0.6)
                .opacity(appeared ? 1 : 0)

            VStack(spacing: 12) {
                Text("Ready to start?")
                    .font(.system(size: 36, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)

                Text("Start typing and watch your fingers\nfly across the keyboard.")
                    .font(.system(size: 18, weight: .regular, design: .rounded))
                    .foregroundStyle(.white.opacity(0.64))
                    .multilineTextAlignment(.center)
                    .lineSpacing(5)
            }
            .opacity(appeared ? 1 : 0)
            .offset(y: appeared ? 0 : 18)

            HStack(spacing: 10) {
                Label("Private by design", systemImage: "lock.shield.fill")
                Label("Runs quietly", systemImage: "waveform")
            }
            .font(.system(size: 13, weight: .medium, design: .rounded))
            .foregroundStyle(.white.opacity(0.42))
            .opacity(appeared ? 1 : 0)

            Spacer(minLength: 10)
        }
        .onAppear {
            withAnimation(.spring(response: 0.65, dampingFraction: 0.75).delay(0.12)) {
                appeared = true
            }
        }
    }
}

private struct OnboardingIcon: View {
    let systemName: String
    let tint: Color

    var body: some View {
        ZStack {
            Circle()
                .fill(.white.opacity(0.08))
                .frame(width: 136, height: 136)

            Circle()
                .strokeBorder(.white.opacity(0.18), lineWidth: 1)
                .frame(width: 136, height: 136)

            Image(systemName: systemName)
                .font(.system(size: 53, weight: .medium))
                .foregroundStyle(tint)
                .symbolRenderingMode(.hierarchical)
        }
    }
}

private struct ProgressPreview: View {
    private let barHeights: [CGFloat] = [30, 46, 38, 62, 54, 75, 68, 91]

    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            HStack {
                Label("Typing rhythm", systemImage: "waveform.path.ecg")
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.82))
                Spacer()
                Text("WPM")
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.35))
            }

            HStack(alignment: .bottom, spacing: 10) {
                ForEach(Array(barHeights.enumerated()), id: \.offset) { index, height in
                    Capsule()
                        .fill(
                            LinearGradient(
                                colors: [.blue.opacity(0.9), .purple.opacity(0.8)],
                                startPoint: .bottom,
                                endPoint: .top
                            )
                        )
                        .frame(width: 20, height: height)
                        .opacity(0.45 + Double(index) * 0.07)
                }
            }
            .frame(maxWidth: .infinity, alignment: .center)
            .frame(height: 92, alignment: .bottom)
        }
        .padding(20)
        .frame(width: 330)
        .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(.white.opacity(0.11), lineWidth: 1))
    }
}
