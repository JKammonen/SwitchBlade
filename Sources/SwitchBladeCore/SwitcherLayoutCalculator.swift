import CoreGraphics

/// Pure-function panel-layout math, extracted from `SwitcherPanelController` so
/// it can be unit-tested without touching NSPanel or NSScreen.
enum SwitcherLayoutCalculator {
    struct Input {
        let visibleFrame: CGRect        // screen's visibleFrame
        let tileMinWidth: CGFloat       // SwitchBladeSettings.tileMinWidth
        let itemCount: Int
        let tileAspectRatio: CGFloat    // SwitcherLayout.tileAspectRatio
    }

    struct Output: Equatable {
        let panelFrame: CGRect          // origin + size centred on screen
        let columns: Int                // actual columns rendered
        let rows: Int                   // actual rows rendered
    }

    // Layout constants — kept in sync with SwitcherView padding values.
    static let gap: CGFloat         = 10
    static let gridPadX: CGFloat    = 14            // .padding(14)
    static let gridPadY: CGFloat    = 14 + 6        // .padding(14) + .padding(.vertical, 6)
    static let cardMarginX: CGFloat = 20            // .padding(.horizontal, 20) outside card
    static let cardMarginY: CGFloat = 12            // .padding(.vertical, 12) outside card
    static let verticalSafety: CGFloat = 4

    static func calculate(_ input: Input) -> Output {
        let frame = input.visibleFrame
        let tileW = input.tileMinWidth
        let itemCount = max(0, input.itemCount)

        let maxWidth = min(frame.width - 40, 1400)
        let maxCardWidth = maxWidth - cardMarginX * 2
        let maxGridWidth = max(tileW, maxCardWidth - gridPadX * 2)

        // Upper bound on columns from screen width.
        let maxColumns = max(1, Int((maxGridWidth + gap) / (tileW + gap)))

        // Shrink and balance to actual item count so small sets don't reserve
        // awkward empty slots (e.g. 5 items as 4+1). Prefer 3+2 or 4+4 style
        // packing until the list is large enough that max-width scanning wins.
        let columns = balancedColumnCount(itemCount: itemCount, maxColumns: maxColumns)
        let rows = max(1, Int(ceil(Double(max(1, itemCount)) / Double(columns))))

        // Per-tile width computed against the wide grid, but applied to the actual
        // column count so visual tile size stays consistent regardless of item count.
        let columnW = (maxGridWidth - CGFloat(maxColumns - 1) * gap) / CGFloat(maxColumns)
        let tileH = columnW / input.tileAspectRatio

        let gridWidth = CGFloat(columns) * columnW + CGFloat(columns - 1) * gap
        let gridH = CGFloat(rows) * tileH + CGFloat(rows - 1) * gap + gridPadY * 2
        let cardH = min(gridH, frame.height * 0.80)
        let height = cardH + cardMarginY * 2 + verticalSafety
        let width = gridWidth + gridPadX * 2 + cardMarginX * 2

        let origin = CGPoint(x: frame.midX - width / 2,
                             y: frame.midY - height / 2)
        let panelFrame = CGRect(origin: origin,
                                size: CGSize(width: width, height: height))

        return Output(panelFrame: panelFrame, columns: columns, rows: rows)
    }

    static func balancedColumnCount(itemCount: Int, maxColumns: Int) -> Int {
        let count = max(1, itemCount)
        let upperBound = max(1, min(maxColumns, count))

        // For large sets, keep the panel dense and wide; users are scanning.
        guard count <= maxColumns * 2 else {
            return upperBound
        }

        return (1...upperBound).min { lhs, rhs in
            score(columnCount: lhs, itemCount: count) < score(columnCount: rhs, itemCount: count)
        } ?? upperBound
    }

    private static func score(columnCount: Int, itemCount: Int) -> Int {
        let rows = Int(ceil(Double(itemCount) / Double(columnCount)))
        let emptySlots = rows * columnCount - itemCount
        let lastRowCount = itemCount % columnCount
        let lonelyLastRowPenalty = lastRowCount == 1 ? 4 : 0
        return emptySlots * 10 + lonelyLastRowPenalty + rows * 5
    }
}
