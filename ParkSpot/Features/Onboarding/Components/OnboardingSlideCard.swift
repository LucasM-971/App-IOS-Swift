import SwiftUI

struct OnboardingSlideCard: View {
    let slide: OnboardingSlide
    let primaryBlue: Color
    let isDarkMode: Bool

    var body: some View {
        VStack(spacing: 24) {
            Spacer(minLength: 26)

            ZStack {
                Circle()
                    .fill(primaryBlue.opacity(isDarkMode ? 0.16 : 0.10))
                    .frame(width: 220, height: 220)

                Circle()
                    .fill(isDarkMode ? Color.white.opacity(0.10) : .white.opacity(0.42))
                    .background(.ultraThinMaterial, in: Circle())
                    .overlay {
                        Circle()
                            .stroke(isDarkMode ? .white.opacity(0.20) : .white.opacity(0.56), lineWidth: 1)
                    }
                    .frame(width: 138, height: 138)
                    .shadow(color: .black.opacity(isDarkMode ? 0.22 : 0.05), radius: 20, y: 10)

                Image(systemName: slide.icon)
                    .font(.system(size: 52, weight: .bold))
                    .foregroundStyle(primaryBlue)
                    .shadow(color: .black.opacity(0.06), radius: 4, y: 2)
            }

            VStack(spacing: 8) {
                Text(slide.title)
                    .font(.system(size: 36, weight: .bold))
                    .multilineTextAlignment(.center)
                    .kerning(-0.3)
                    .lineLimit(2)
                    .minimumScaleFactor(0.86)
                    .fixedSize(horizontal: false, vertical: true)
                    .foregroundStyle(isDarkMode ? .white.opacity(0.94) : .black.opacity(0.9))

                Text(slide.subtitle)
                    .font(.system(size: 17, weight: .medium))
                    .foregroundColor(isDarkMode ? .white.opacity(0.66) : .black.opacity(0.52))
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .minimumScaleFactor(0.9)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 18)

            Spacer(minLength: 40)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
