import UIKit

/// Reserved regions overlapping a view, in that view's coordinates.
struct ReservedLayoutRegions: Equatable {
    /// Areas that cover content (camera, Dynamic Island).
    var occlusions: [CGRect] = []
    /// Areas that split content (the iPhone Duo fold while partly folded).
    var divisions: [CGRect] = []
}

/// The only file that touches iOS 27.1 iPhone Duo API. Everything is behind `#available`; on older
/// systems it reports no regions and no hinge, and the layout falls back to bounds + safe area.
///
/// Declarations used, as published in Apple's documentation JSON (fetched 2026-11-24):
/// - `@MainActor func reservedRegions(kind: UIView.ReservedRegion.Kind,
///    options: UIView.ReservedRegion.QueryOptions = []) -> [UIView.ReservedRegion]` (iOS 27.1)
/// - `UIView.ReservedRegion.Kind.occlusion`, `.division`; `ReservedRegion.frame: CGRect` (view
///   coordinates, margins included); default query returns only active regions.
/// - `@MainActor class UIHingeInteraction`, `init(updateHandler: @escaping (UIHingeInteraction,
///    UIHingeInteraction.Update) -> Void)`, added with `view.addInteraction(_:)`.
/// UIKit re-runs `updateConstraints()` of a view that read regions there when they change; the
/// session root view reads them in `updateConstraints()` for that reason.
@MainActor
enum DuoHardware {
    static func reservedRegions(in view: UIView) -> ReservedLayoutRegions {
        if #available(iOS 27.1, *) {
            let occlusions: [CGRect] = view.reservedRegions(kind: .occlusion).map { (r: UIView.ReservedRegion) -> CGRect in r.frame }
            let divisions: [CGRect] = view.reservedRegions(kind: .division).map { (r: UIView.ReservedRegion) -> CGRect in r.frame }
            return ReservedLayoutRegions(occlusions: occlusions, divisions: divisions)
        }
        return ReservedLayoutRegions()
    }

    /// Calls `onChange` whenever the hinge state changes (fold / unfold). Returns the interaction
    /// (keep it alive with the view), or nil before iOS 27.1. Folding only changes the layout; the
    /// session keeps running.
    static func observeHinge(on view: UIView, onChange: @escaping () -> Void) -> AnyObject? {
        if #available(iOS 27.1, *) {
            let interaction: UIHingeInteraction = UIHingeInteraction(updateHandler: { (_: UIHingeInteraction, _: UIHingeInteraction.Update) in
                onChange()
            })
            view.addInteraction(interaction)
            return interaction
        }
        return nil
    }
}
