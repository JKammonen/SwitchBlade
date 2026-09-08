import CoreGraphics

/// Pure-function panel-layout math, extracted from `SwitcherPanelController` so
/// it can be unit-tested without touching NSPanel or NSScreen.
enum SwitcherLayoutCalculator {
    struct Input {
        let visibleFrame: CGRect        // screen's visibleFrame
        let tileMinWidth: CGFloat       // SwitchBladeSettings.tileMinWidth
        let itemCount: Int
        let tileAspectRatio: CGFloat    // SwitcherLayout.tileAspectRatio
        var selectorWidthFraction: CGFloat = 0.8
        var showsPermissionFooter = false
    }

    struct Output: Equatable {
        let panelFrame: CGRect          // origin + size centred on screen
        let columns: Int                // actual columns rendered
        let rows: Int                   // actual rows rendered
        let tileWidth: CGFloat          // actual width rendered for each preview tile
    }

    // Layout constants — kept in sync with SwitcherView padding values.
    static let gap: CGFloat         = 10
    static let gridPadX: CGFloat    = 14            // .padding(14)
    static let gridPadY: CGFloat    = 14 + 6        // .padding(14) + .padding(.vertical, 6)
    static let cardMarginX: CGFloat = 20            // .padding(.horizontal, 20) outside card
    static let cardMarginY: CGFloat = 12            // .padding(.vertical, 12) outside card
    static let verticalSafety: CGFloat = 4
    static let headerHeight: CGFloat = 34
    /// Exact vertical space reserved by SwitcherView for its permission row.
    static let permissionFooterHeight: CGFloat = 42
    static let screenMargin: CGFloat = 20
    private static let minimumAdaptiveTileWidth: CGFloat = 140

    static func calculate(_ input: Input) -> Output {
        let frame = input.visibleFrame
        let requestedTileWidth = input.tileMinWidth.isFinite && input.tileMinWidth > 0
            ? input.tileMinWidth
            : 220
        let tileAspectRatio = input.tileAspectRatio.isFinite && input.tileAspectRatio > 0
            ? input.tileAspectRatio
            : 1.65
        let selectorWidthFraction = input.selectorWidthFraction.isFinite
            ? min(max(input.selectorWidthFraction, 0.5), 0.95)
            : 0.8
        let itemCount = max(0, input.itemCount)

        let requestedSelectorWidth = frame.width * selectorWidthFraction
        let maxPanelWidth = max(1, min(frame.width - screenMargin * 2, requestedSelectorWidth))
        let horizontalChrome = cardMarginX * 2 + gridPadX * 2
        let maxGridWidth = max(1, maxPanelWidth - horizontalChrome)
        let tileW = min(requestedTileWidth, maxGridWidth)

        // Upper bound on columns from screen width.
        let maxColumns = max(1, Int((maxGridWidth + gap) / (tileW + gap)))

        // Shrink and balance to actual item count so small sets don't reserve
        // awkward empty slots (e.g. 5 items as 4+1). Prefer 3+2 or 4+4 style
        // packing until the list is large enough that max-width scanning wins.
        let preferredColumns = balancedColumnCount(itemCount: itemCount, maxColumns: maxColumns)

        let verticalChrome = cardMarginY * 2 + verticalSafety
        let maxCardHeight = max(1, min(frame.height * 0.80, frame.height - verticalChrome))
        let footerHeight = input.showsPermissionFooter ? permissionFooterHeight : 0
        let fittedGrid = gridFittingHeight(
            itemCount: itemCount,
            preferredColumns: preferredColumns,
            requestedTileWidth: tileW,
            maxGridWidth: maxGridWidth,
            tileAspectRatio: tileAspectRatio,
            maxCardHeight: maxCardHeight,
            footerHeight: footerHeight
        )
        let columns = fittedGrid.columns
        let rows = fittedGrid.rows

        // Keep the rendered tile width tied to the setting. Previously the grid
        // redistributed all available width after a column-count threshold, so
        // 250 -> 260 pt could render as 250 -> 316 pt. The only exception is a
        // height overflow: reduce tiles just enough to keep every row visible.
        let renderedTileWidth = fittedGrid.tileWidth
        let tileH = renderedTileWidth / tileAspectRatio

        let contentGridWidth = CGFloat(columns) * renderedTileWidth + CGFloat(columns - 1) * gap
        // The selector setting is a maximum width. Keep dense, max-column grids
        // stable across tile-width thresholds, but when balancing deliberately
        // removes columns, shrink the panel around the resulting grid instead of
        // leaving large empty margins on both sides.
        let fillsSelectorWidth = itemCount > maxColumns * 2 && columns == maxColumns
        let gridWidth = fillsSelectorWidth ? maxGridWidth : contentGridWidth
        let gridH = CGFloat(rows) * tileH + CGFloat(rows - 1) * gap + gridPadY * 2
        let cardH = min(headerHeight + gridH + footerHeight, maxCardHeight)
        let height = min(frame.height, cardH + verticalChrome)
        let width = min(frame.width, gridWidth + horizontalChrome)

        let origin = CGPoint(x: frame.midX - width / 2,
                             y: frame.midY - height / 2)
        let panelFrame = CGRect(origin: origin,
                                size: CGSize(width: width, height: height))

        return Output(panelFrame: panelFrame, columns: columns, rows: rows, tileWidth: renderedTileWidth)
    }

    private static func gridFittingHeight(
        itemCount: Int,
        preferredColumns: Int,
        requestedTileWidth: CGFloat,
        maxGridWidth: CGFloat,
        tileAspectRatio: CGFloat,
        maxCardHeight: CGFloat,
        footerHeight: CGFloat
    ) -> (columns: Int, rows: Int, tileWidth: CGFloat) {
        let count = max(1, itemCount)
        let preferredRows = Int(ceil(Double(count) / Double(preferredColumns)))
        let preferredHeight = headerHeight
            + CGFloat(preferredRows) * (requestedTileWidth / tileAspectRatio)
            + CGFloat(preferredRows - 1) * gap
            + gridPadY * 2
            + footerHeight
        guard preferredHeight > maxCardHeight else {
            return (preferredColumns, preferredRows, requestedTileWidth)
        }

        // A wider grid often preserves much larger previews than squeezing an
        // extra row vertically. Never shrink below the settings slider's real
        // lower bound; very large result sets remain scrollable instead.
        let adaptiveFloor = min(requestedTileWidth, minimumAdaptiveTileWidth)
        let maxAdaptiveColumns = min(
            count,
            max(preferredColumns, Int((maxGridWidth + gap) / (adaptiveFloor + gap)))
        )
        var best: (columns: Int, rows: Int, tileWidth: CGFloat)?

        for columns in preferredColumns...maxAdaptiveColumns {
            let rows = Int(ceil(Double(count) / Double(columns)))
            let horizontalLimit = (maxGridWidth - CGFloat(columns - 1) * gap) / CGFloat(columns)
            let verticalSpace = maxCardHeight
                - headerHeight
                - footerHeight
                - gridPadY * 2
                - CGFloat(rows - 1) * gap
            let verticalLimit = (verticalSpace / CGFloat(rows)) * tileAspectRatio
            let candidateWidth = min(requestedTileWidth, horizontalLimit, verticalLimit)
            guard candidateWidth.isFinite, candidateWidth + 0.5 >= adaptiveFloor else { continue }

            if let best, candidateWidth <= best.tileWidth + 0.5 {
                continue
            } else {
                best = (columns, rows, candidateWidth)
            }
        }

        return best ?? (preferredColumns, preferredRows, requestedTileWidth)
    }

    static func balancedColumnCount(itemCount: Int, maxColumns: Int) -> Int {
        let count = max(1, itemCount)
        let upperBound = max(1, min(maxColumns, count))

        // For dense sets, keep the minimum row count but reduce the columns to
        // the smallest count that still fits those rows. This avoids orphaned
        // final rows such as 7 + 7 + 1 without shrinking the configured tiles.
        guard count <= maxColumns * 2 else {
            let rows = Int(ceil(Double(count) / Double(upperBound)))
            return Int(ceil(Double(count) / Double(rows)))
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
