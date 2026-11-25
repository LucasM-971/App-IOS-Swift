import SwiftUI

struct LaunchLoadingView: View {
    @Environment(\.colorScheme) private var colorScheme
    @State private var animate = false

    private var backgroundColor: Color {
        colorScheme == .dark ? .black : .white
    }

    private var titleColor: Color {
        colorScheme == .dark ? .white : .black
    }

    private var subtitleColor: Color {
        colorScheme == .dark ? .white.opacity(0.78) : .black.opacity(0.62)
    }

    private var haloColor: Color {
        colorScheme == .dark ? .white.opacity(0.08) : Color("BrandBlue").opacity(0.12)
    }

    private var logoBorderColor: Color {
        colorScheme == .dark ? .white.opacity(0.18) : .black.opacity(0.08)
    }

    var body: some View {
        ZStack {
            backgroundColor
                .ignoresSafeArea()

            VStack(spacing: 22) {
                ZStack {
                    Circle()
                        .fill(haloColor)
                        .frame(width: 128, height: 128)
                        .scaleEffect(animate ? 1.08 : 0.92)
                        .animation(
                            animate
                                ? .easeInOut(duration: 1.1).repeatForever(autoreverses: true)
                                : .default,
                            value: animate
                        )

                    Image("BrandLogo")
                        .resizable()
                        .scaledToFill()
                        .frame(width: 96, height: 96)
                        .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: 28, style: .continuous)
                                .stroke(logoBorderColor, lineWidth: 1)
                        }
                        .shadow(color: .black.opacity(0.14), radius: 18, y: 12)
                }

                VStack(spacing: 8) {
                    Text("MosiMap".psLocalized)
                        .font(.system(size: 34, weight: .bold))
                        .foregroundStyle(titleColor)

                    Text("Préparation de votre session…".psLocalized)
                        .font(.subheadline)
                        .foregroundStyle(subtitleColor)
                }

                ProgressView()
                    .tint(Color("BrandBlue"))
                    .scaleEffect(1.15)
                    .padding(.top, 8)
            }
            .padding(.horizontal, 24)
        }
        .onAppear {
            animate = true
        }
        .onDisappear {
            animate = false
        }
    }
}
