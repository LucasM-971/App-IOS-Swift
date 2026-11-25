import SwiftUI

struct LegalSection: Identifiable {
    let id: String
    let title: String
    let paragraphs: [String]
    let bullets: [String]
    let note: String?

    init(title: String, paragraphs: [String], bullets: [String] = [], note: String? = nil) {
        self.id = title
        self.title = title
        self.paragraphs = paragraphs
        self.bullets = bullets
        self.note = note
    }
}

private struct LegalFact: Identifiable {
    let id: String
    let icon: String
    let label: String
    let value: String

    init(icon: String, label: String, value: String) {
        self.id = label
        self.icon = icon
        self.label = label
        self.value = value
    }
}

private struct LegalDocument {
    let title: String
    let eyebrow: String
    let subtitle: String
    let icon: String
    let tint: Color
    let summary: String
    let facts: [LegalFact]
    let sections: [LegalSection]
    let webURL: URL
    let contactLabel: String
    let contactEmail: String
}

private struct LegalDocumentView: View {
    let document: LegalDocument

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                hero
                summary
                facts

                ForEach(document.sections) { section in
                    LegalSectionCard(section: section, tint: document.tint)
                }

                footer
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.vertical, 18)
        }
        .background(Color(UIColor.systemGroupedBackground))
        .navigationTitle(document.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbarBackground(Color(.systemBackground), for: .navigationBar)
    }

    private var hero: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: document.icon)
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 46, height: 46)
                    .background(document.tint, in: RoundedRectangle(cornerRadius: 12, style: .continuous))

                VStack(alignment: .leading, spacing: 4) {
                    Text(document.eyebrow)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(document.tint)
                        .textCase(.uppercase)

                    Text(document.title)
                        .font(.title2.weight(.bold))
                        .foregroundStyle(.primary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Text(document.subtitle)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(UIColor.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(document.tint.opacity(0.18), lineWidth: 1)
        )
    }

    private var summary: some View {
        Text(document.summary)
            .font(.body)
            .foregroundStyle(.primary)
            .lineSpacing(3)
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(UIColor.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var facts: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("At a glance")
                .font(.headline)
                .foregroundStyle(.primary)

            VStack(spacing: 8) {
                ForEach(document.facts) { fact in
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: fact.icon)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(document.tint)
                            .frame(width: 24, height: 24)

                        VStack(alignment: .leading, spacing: 2) {
                            Text(fact.label)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .textCase(.uppercase)

                            Text(fact.value)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.primary)
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        Spacer(minLength: 0)
                    }
                    .padding(12)
                    .background(Color(UIColor.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
            }
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 12) {
            Link(destination: document.webURL) {
                Label("Open web version", systemImage: "safari")
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            if let mailURL = mailURL(for: document.contactEmail) {
                Link(destination: mailURL) {
                    Label(document.contactLabel, systemImage: "envelope")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .foregroundStyle(document.tint)
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(UIColor.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func mailURL(for email: String) -> URL? {
        let trimmed = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return URL(string: "mailto:\(trimmed)")
    }
}

private struct LegalSectionCard: View {
    let section: LegalSection
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(section.title)
                .font(.headline.weight(.bold))
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)

            ForEach(section.paragraphs, id: \.self) { paragraph in
                Text(paragraph)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !section.bullets.isEmpty {
                VStack(alignment: .leading, spacing: 9) {
                    ForEach(section.bullets, id: \.self) { bullet in
                        HStack(alignment: .top, spacing: 10) {
                            Circle()
                                .fill(tint)
                                .frame(width: 6, height: 6)
                                .padding(.top, 7)

                            Text(bullet)
                                .font(.subheadline)
                                .foregroundStyle(.primary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .padding(.top, 2)
            }

            if let note = section.note, !note.isEmpty {
                Text(note)
                    .font(.footnote)
                    .foregroundStyle(tint)
                    .lineSpacing(2)
                    .padding(.top, 2)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(UIColor.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.primary.opacity(0.06), lineWidth: 1)
        )
    }
}

struct PrivacyPolicyView: View {
    var body: some View {
        LegalDocumentView(document: .privacyPolicy)
    }
}

struct TermsOfUseView: View {
    var body: some View {
        LegalDocumentView(document: .termsOfUse)
    }
}

private extension LegalDocument {
    static var privacyPolicy: LegalDocument {
        LegalDocument(
            title: String(localized: "settings.privacy_policy"),
            eyebrow: "Privacy",
            subtitle: "Last updated: May 1, 2026",
            icon: "hand.raised.fill",
            tint: .teal,
            summary: "MosiMap uses personal data only to run parking features, keep your account synced, process purchases, improve reliability, and provide optional ads. We do not sell your personal data, and you can export or delete your data from Settings or by contacting us.",
            facts: [
                .init(icon: "location.fill", label: "Main data", value: "Precise location, saved parking sessions, account details"),
                .init(icon: "lock.shield.fill", label: "Tracking", value: "No sale of personal data; ads may use advertising identifiers where allowed"),
                .init(icon: "trash.fill", label: "Control", value: "Export or delete account data from Settings"),
                .init(icon: "envelope.fill", label: "Contact", value: AppConfig.dataRequestEmail)
            ],
            sections: [
                .init(
                    title: "1. Who this policy covers",
                    paragraphs: [
                        "This policy explains how MosiMap collects, uses, stores, and protects personal data when you use the iOS app, widgets, notifications, CarPlay features, and related services."
                    ]
                ),
                .init(
                    title: "2. Data we collect",
                    paragraphs: [
                        "The exact data depends on the features you choose to use."
                    ],
                    bullets: [
                        "Account data: email address, display name, user identifier, authentication status, and subscription status.",
                        "Parking and location data: current location, saved parking position, parking history, distance to your car, parking level, reminders, and related timestamps.",
                        "Optional content: parking notes, reference photos, profile photo, and frequent-zone names you create.",
                        "Device and app data: settings, notification preferences, app diagnostics, crash or performance signals, and local app state.",
                        "Purchase and advertising data: Apple purchase status for subscriptions or lifetime access, and advertising identifiers or ad events when ads are displayed."
                    ]
                ),
                .init(
                    title: "3. How we use data",
                    paragraphs: [
                        "We use data to provide and maintain the app, including saving your car location, guiding you back, sending reminders, syncing sessions, showing widgets or Live Activities, supporting CarPlay, and managing premium access."
                    ],
                    bullets: [
                        "Operate accounts, authentication, support requests, exports, and deletion requests.",
                        "Improve reliability, diagnose problems, prevent abuse, and protect the service.",
                        "Personalize parking reminders, frequent zones, and smart detection when enabled.",
                        "Show ads to free users where applicable and allowed by your device settings."
                    ]
                ),
                .init(
                    title: "4. Location and background features",
                    paragraphs: [
                        "Location is central to MosiMap, but you stay in control. Precise location is used to save your parking spot, estimate your distance from the vehicle, and help you navigate back.",
                        "Background location, automatic parking detection, Bluetooth-assisted detection, and CarPlay-related reminders are optional features. You can disable them in the app or in iOS Settings."
                    ]
                ),
                .init(
                    title: "5. Legal bases under GDPR",
                    paragraphs: [
                        "Where GDPR applies, processing may rely on contract performance for core app features, consent for optional permissions such as location or notifications, legitimate interests for security and reliability, and legal obligations where required."
                    ]
                ),
                .init(
                    title: "6. Sharing and service providers",
                    paragraphs: [
                        "We use trusted providers to operate the service. They process data only as needed to provide their services to MosiMap."
                    ],
                    bullets: [
                        "Supabase for authentication, account data, and parking session storage.",
                        "Apple for App Store purchases, subscriptions, notifications, and platform services.",
                        "Google AdMob for advertising in free experiences where ads are enabled.",
                        "Diagnostics, hosting, and support tools used to maintain the app."
                    ],
                    note: "We do not sell your personal data."
                ),
                .init(
                    title: "7. Retention",
                    paragraphs: [
                        "We keep personal data only as long as needed for the purposes described in this policy. Active parking data, history, notes, and photos remain available until you delete them, delete your account, or a retention rule applies.",
                        "Backups and security logs may remain for a limited time before deletion or anonymization."
                    ]
                ),
                .init(
                    title: "8. Your rights",
                    paragraphs: [
                        "Depending on your location, you may have rights to access, correct, export, restrict, object to, or delete your personal data. You may also withdraw consent for optional permissions at any time."
                    ],
                    bullets: [
                        "Use Settings to export your data or request account deletion.",
                        "Contact us for privacy questions, access requests, corrections, or deletion requests.",
                        "You may lodge a complaint with your local data protection authority if you believe your rights have not been respected."
                    ]
                ),
                .init(
                    title: "9. Security and transfers",
                    paragraphs: [
                        "We use technical and organizational safeguards designed to protect your data, including access controls and secure transport. No method of transmission or storage is perfectly secure, so we continue to improve protections over time.",
                        "If data is processed outside your country, we rely on appropriate safeguards required by applicable law."
                    ]
                ),
                .init(
                    title: "10. Changes and contact",
                    paragraphs: [
                        "We may update this policy when the app, providers, or legal requirements change. Important changes will be shown in the app or through another appropriate notice.",
                        "For privacy requests, contact us at \(AppConfig.dataRequestEmail)."
                    ]
                )
            ],
            webURL: AppConfig.privacyPolicyURL,
            contactLabel: "Contact privacy support",
            contactEmail: AppConfig.dataRequestEmail
        )
    }

    static var termsOfUse: LegalDocument {
        LegalDocument(
            title: String(localized: "settings.terms"),
            eyebrow: "Terms",
            subtitle: "Last updated: May 1, 2026",
            icon: "doc.text.fill",
            tint: .indigo,
            summary: "These terms explain how you may use MosiMap. The app helps you save and find your parked car, but you remain responsible for safe driving, parking rules, local regulations, and the choices you make while using it.",
            facts: [
                .init(icon: "car.fill", label: "Purpose", value: "Parking assistance, reminders, widgets, and CarPlay support"),
                .init(icon: "creditcard.fill", label: "Purchases", value: "Subscriptions and lifetime access are handled by Apple"),
                .init(icon: "exclamationmark.triangle.fill", label: "Safety", value: "Do not use the app in a way that distracts from driving"),
                .init(icon: "envelope.fill", label: "Support", value: AppConfig.supportEmail)
            ],
            sections: [
                .init(
                    title: "1. Acceptance",
                    paragraphs: [
                        "By downloading, accessing, or using MosiMap, you agree to these Terms of Use. If you do not agree, do not use the app."
                    ]
                ),
                .init(
                    title: "2. What MosiMap provides",
                    paragraphs: [
                        "MosiMap provides tools to save your parking location, find your vehicle, receive reminders, use widgets and Live Activities, manage parking history, and access optional premium features."
                    ],
                    note: "MosiMap is an assistance tool, not a guarantee that a parking location, reminder, map, or route will always be accurate."
                ),
                .init(
                    title: "3. Account and eligibility",
                    paragraphs: [
                        "You are responsible for keeping your account information accurate and your login credentials secure. You must not use another person's account without permission.",
                        "If you use the app on behalf of another person or organization, you confirm that you have authority to accept these terms for them."
                    ]
                ),
                .init(
                    title: "4. Safe and lawful use",
                    paragraphs: [
                        "You are responsible for complying with traffic rules, parking signs, local laws, and safety requirements. Do not interact with the app while driving unless it is safe and lawful to do so."
                    ],
                    bullets: [
                        "Do not rely on MosiMap as your only source for legal parking information.",
                        "Do not use the app for surveillance, stalking, harassment, or any illegal purpose.",
                        "Do not attempt to bypass security, reverse engineer the service, or disrupt other users."
                    ]
                ),
                .init(
                    title: "5. Subscriptions and purchases",
                    paragraphs: [
                        "Premium features may be offered through auto-renewable subscriptions or lifetime purchases. Purchases are processed by Apple through the App Store.",
                        "Subscription price, duration, renewal terms, trial terms, and included features are shown before purchase. Subscriptions renew automatically unless canceled at least 24 hours before the end of the current period. You can manage or cancel subscriptions in your Apple account settings."
                    ],
                    note: "Refunds, billing issues, and purchase management are handled according to Apple's App Store rules."
                ),
                .init(
                    title: "6. Your content",
                    paragraphs: [
                        "You may add parking notes, photos, profile information, and other optional content. You keep ownership of your content, but you grant MosiMap the limited right to store and process it so the app can provide its features.",
                        "You are responsible for the content you add and must not upload unlawful, harmful, or infringing material."
                    ]
                ),
                .init(
                    title: "7. App availability and changes",
                    paragraphs: [
                        "We work to keep MosiMap available and reliable, but the service may be interrupted, limited, or unavailable because of maintenance, network issues, provider outages, device settings, permissions, or platform changes.",
                        "Features may be updated, added, limited, or removed over time to improve the app, comply with law, or maintain the service."
                    ]
                ),
                .init(
                    title: "8. Intellectual property",
                    paragraphs: [
                        "MosiMap, including its design, software, branding, text, and features, is protected by intellectual property laws. These terms grant you a personal, limited, non-exclusive, non-transferable license to use the app for its intended purpose."
                    ]
                ),
                .init(
                    title: "9. Privacy",
                    paragraphs: [
                        "Use of MosiMap also involves processing personal data. The Privacy Policy explains what data is collected, how it is used, and how you can exercise your rights."
                    ]
                ),
                .init(
                    title: "10. Disclaimers and liability",
                    paragraphs: [
                        "MosiMap is provided on an as-is and as-available basis to the maximum extent permitted by law. We do not promise that every location, notification, prediction, route, or parking record will be complete, timely, or error-free.",
                        "To the maximum extent permitted by law, MosiMap is not liable for indirect losses, parking fines, towing, missed reminders, loss of data, interruption, or decisions made based on app information."
                    ]
                ),
                .init(
                    title: "11. Suspension or termination",
                    paragraphs: [
                        "You may stop using MosiMap at any time. We may suspend or terminate access if we reasonably believe the app is being misused, these terms are violated, or access must be restricted for legal or security reasons."
                    ]
                ),
                .init(
                    title: "12. Changes and contact",
                    paragraphs: [
                        "We may update these terms when the app, business model, or legal requirements change. Important changes will be shown in the app or through another appropriate notice.",
                        "For support or legal questions, contact us at \(AppConfig.supportEmail)."
                    ]
                )
            ],
            webURL: AppConfig.termsURL,
            contactLabel: "Contact support",
            contactEmail: AppConfig.supportEmail
        )
    }
}
