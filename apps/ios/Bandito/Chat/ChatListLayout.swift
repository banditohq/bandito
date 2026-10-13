import UIKit

/// The chat's list: one column of rows, each with the height it was measured at. No self-sizing pass: the heights are
/// known before a row is shown, so a row never changes size when it scrolls in (nothing jumps), and the layout is a
/// running sum.
final class ChatListLayout: UICollectionViewLayout {
    private var heights: [CGFloat] = []
    private var spacings: [CGFloat] = []
    private var tops: [CGFloat] = []
    private var total: CGFloat = 0
    private var width: CGFloat = 0

    var topPadding: CGFloat = 12
    var bottomPadding: CGFloat = 10

    /// Sets the rows' heights and the space above each, in the order of the list.
    func setRows(heights: [CGFloat], spacings: [CGFloat]) {
        self.heights = heights
        self.spacings = spacings
        recompute()
        invalidateLayout()
    }

    private func recompute() {
        var y = topPadding
        tops = []
        tops.reserveCapacity(heights.count)
        for index in heights.indices {
            y += spacings[index]
            tops.append(y)
            y += heights[index]
        }
        total = y + bottomPadding
    }

    func frame(at index: Int) -> CGRect? {
        guard tops.indices.contains(index) else { return nil }
        return CGRect(x: 0, y: tops[index], width: width, height: heights[index])
    }

    override func prepare() {
        super.prepare()
        width = collectionView?.bounds.width ?? 0
    }

    override var collectionViewContentSize: CGSize {
        CGSize(width: collectionView?.bounds.width ?? width, height: total)
    }

    override func layoutAttributesForElements(in rect: CGRect) -> [UICollectionViewLayoutAttributes]? {
        guard !tops.isEmpty else { return [] }
        // The first row whose bottom is below the rect's top (binary search), then rows until the rect's bottom.
        var low = 0, high = tops.count
        while low < high {
            let mid = (low + high) / 2
            if tops[mid] + heights[mid] < rect.minY { low = mid + 1 } else { high = mid }
        }
        var result: [UICollectionViewLayoutAttributes] = []
        var index = low
        let limit = collectionView?.numberOfItems(inSection: 0) ?? 0
        while index < tops.count, index < limit, tops[index] <= rect.maxY {
            result.append(attributes(at: index))
            index += 1
        }
        return result
    }

    override func layoutAttributesForItem(at indexPath: IndexPath) -> UICollectionViewLayoutAttributes? {
        guard tops.indices.contains(indexPath.item) else { return nil }
        return attributes(at: indexPath.item)
    }

    private func attributes(at index: Int) -> UICollectionViewLayoutAttributes {
        let attributes = UICollectionViewLayoutAttributes(forCellWith: IndexPath(item: index, section: 0))
        attributes.frame = CGRect(x: 0, y: tops[index], width: width, height: heights[index])
        return attributes
    }

    override func shouldInvalidateLayout(forBoundsChange newBounds: CGRect) -> Bool {
        newBounds.width != width
    }
}
