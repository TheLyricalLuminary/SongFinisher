import SwiftUI
import StoreKit

/// The Pro paywall: unlimited on-device AI generations. Reached from the free-limit
/// upsell in `SessionView` and the crown button in `SongListView`. Custom layout rather
/// than `SubscriptionStoreView` because the lifetime unlock (a non-consumable) sits
/// alongside the subscription group and Apple's stock view can't mix the two.
struct PaywallView: View {
    let store: ProStore

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                header

                if store.isPro {
                    proBadge
                } else if store.products.isEmpty {
                    unavailableNote
                } else {
                    productButtons
                }

                if let error = store.purchaseError {
                    Text(error)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                }

                Button("Restore Purchases") {
                    Task { await store.restorePurchases() }
                }
                .font(.footnote)
                .tint(.secondary)

                Text("Offline draft suggestions are always free and unlimited.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
            }
            .padding(24)
        }
        .appBackground()
        .overlay(alignment: .topTrailing) {
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.title2)
                    .foregroundStyle(.secondary, .quaternary)
            }
            .buttonStyle(.plain)
            .padding(12)
            .accessibilityLabel("Close")
        }
    }

    private var header: some View {
        VStack(spacing: 12) {
            Image(systemName: "sparkles")
                .font(.system(size: 44, weight: .medium))
                .foregroundStyle(Color.brand)
                .padding(.top, 24)

            Text("Song Finisher Pro")
                .font(.title.weight(.bold))

            VStack(alignment: .leading, spacing: 10) {
                benefit("infinity", "Unlimited AI lines, matched to your melody")
                benefit("iphone.and.arrow.forward", "Everything stays on your device — no account")
                benefit("square.and.arrow.up", "Support an independent songwriting tool")
            }
            .padding(.top, 4)
        }
        .accessibilityElement(children: .combine)
    }

    private func benefit(_ icon: String, _ text: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .foregroundStyle(Color.brand)
                .frame(width: 24)
            Text(text)
                .font(.subheadline)
        }
    }

    private var productButtons: some View {
        VStack(spacing: 12) {
            ForEach(store.products, id: \.id) { product in
                ProductButton(product: product, isHighlighted: product.id == ProStore.ProductID.yearly) {
                    Task { await store.purchase(product) }
                }
            }
        }
    }

    private var proBadge: some View {
        VStack(spacing: 8) {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 36))
                .foregroundStyle(Color.brand)
            Text("You're Pro. Every line is unlimited.")
                .font(.headline)
        }
        .padding(.vertical, 20)
        .accessibilityElement(children: .combine)
    }

    private var unavailableNote: some View {
        Text("Purchases aren't available right now. Your free daily suggestions still work — try again later.")
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .padding(.vertical, 20)
    }
}

private struct ProductButton: View {
    let product: Product
    let isHighlighted: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(product.displayName)
                            .font(.headline)
                        if isHighlighted {
                            Text("BEST VALUE")
                                .font(.caption2.weight(.bold))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.brand.opacity(0.15), in: Capsule())
                                .foregroundStyle(Color.brand)
                        }
                    }
                    Text(periodLabel)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text(product.displayPrice)
                    .font(.headline)
            }
            .padding(16)
            .background(
                RoundedRectangle(cornerRadius: 14)
                    .strokeBorder(isHighlighted ? Color.brand : Color.secondary.opacity(0.3), lineWidth: isHighlighted ? 2 : 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(product.displayName), \(product.displayPrice), \(periodLabel)")
        .accessibilityHint("Purchases \(product.displayName)")
    }

    private var periodLabel: String {
        guard let period = product.subscription?.subscriptionPeriod else { return "One-time purchase" }
        switch period.unit {
        case .month: "per month, cancel anytime"
        case .year: "per year, cancel anytime"
        case .week: "per week, cancel anytime"
        case .day: "per day, cancel anytime"
        @unknown default: "subscription"
        }
    }
}
