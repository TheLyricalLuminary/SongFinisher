import Foundation
import StoreKit

/// The decision `SessionViewModel` asks before each generation: premium provider or
/// offline drafts? Kept as a protocol so tests and previews can run unmetered.
@MainActor
protocol GenerationGating: AnyObject {
    /// True → run the premium (on-device AI) provider. Counts against the free-tier
    /// daily budget unless the user owns Pro.
    func allowPremiumGeneration() -> Bool
}

/// StoreKit 2 composition point for Song Finisher Pro: loads the three products, tracks
/// the entitlement across purchases/renewals/refunds via `Transaction.updates`, and owns
/// the free-tier `GenerationAllowance`. Created once at app launch and passed down the
/// view tree; there is no server — StoreKit's on-device verification is the source of
/// truth, consistent with the app's no-account, no-cloud architecture.
@MainActor
@Observable
final class ProStore: GenerationGating {
    enum ProductID {
        static let monthly = "com.songfinisher.pro.monthly"
        static let yearly = "com.songfinisher.pro.yearly"
        static let lifetime = "com.songfinisher.pro.lifetime"
        static let all: Set<String> = [monthly, yearly, lifetime]
    }

    private(set) var isPro = false
    /// Sorted cheapest-first (monthly, yearly, lifetime). Empty while loading or when
    /// the store is unreachable — the paywall shows a graceful fallback for that.
    private(set) var products: [Product] = []
    private(set) var purchaseError: String?

    let allowance: GenerationAllowance

    private var updatesTask: Task<Void, Never>?

    init(allowance: GenerationAllowance = GenerationAllowance()) {
        self.allowance = allowance
        updatesTask = Task { [weak self] in
            for await update in Transaction.updates {
                if case .verified(let transaction) = update {
                    await transaction.finish()
                }
                await self?.refreshEntitlement()
            }
        }
        Task { [weak self] in
            await self?.loadProducts()
            await self?.refreshEntitlement()
        }
    }

    func allowPremiumGeneration() -> Bool {
        #if DEBUG
        // Development builds are never metered. The daily free budget exists to shape a
        // shipping user's upgrade decision; applied to the author's own machine it just
        // blocks testing and — worse — silently degrades a demo recording to OFFLINE
        // DRAFT partway through, since every regenerate/more-like-this/syllable-nudge
        // spends a credit. Release builds still meter exactly as before.
        return true
        #else
        return isPro || allowance.consume()
        #endif
    }

    func loadProducts() async {
        guard let loaded = try? await Product.products(for: ProductID.all) else { return }
        products = loaded.sorted { $0.price < $1.price }
    }

    func refreshEntitlement() async {
        var pro = false
        for await entitlement in Transaction.currentEntitlements {
            if case .verified(let transaction) = entitlement,
               ProductID.all.contains(transaction.productID),
               transaction.revocationDate == nil {
                pro = true
            }
        }
        isPro = pro
    }

    func purchase(_ product: Product) async {
        purchaseError = nil
        do {
            switch try await product.purchase() {
            case .success(let verification):
                if case .verified(let transaction) = verification {
                    await transaction.finish()
                }
                await refreshEntitlement()
            case .userCancelled, .pending:
                break
            @unknown default:
                break
            }
        } catch {
            purchaseError = error.localizedDescription
        }
    }

    func restorePurchases() async {
        purchaseError = nil
        do {
            try await AppStore.sync()
        } catch {
            purchaseError = error.localizedDescription
        }
        await refreshEntitlement()
    }
}
