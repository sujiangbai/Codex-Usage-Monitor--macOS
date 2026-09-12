import Foundation
import CoreGraphics

// All inputs are screen coordinates in points, never backing pixels. Keep the
// top anchored when content grows/shrinks and avoid menu bar, notch and Dock.
func quotaPanelFrame(contentSize: CGSize, anchor: CGRect, visibleFrame: CGRect) -> CGRect {
    let safe = visibleFrame.insetBy(dx: 8, dy: 8)
    let width = min(max(1, ceil(contentSize.width)), max(1, safe.width))
    let top = max(safe.minY + 1, min(anchor.minY - 6, safe.maxY))
    let height = min(max(1, ceil(contentSize.height)), max(1, top - safe.minY))
    let x = min(max(anchor.midX - width / 2, safe.minX), safe.maxX - width)
    return CGRect(x: floor(x), y: top - height, width: width, height: height)
}
