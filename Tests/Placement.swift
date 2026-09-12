import Foundation
import CoreGraphics

@main enum PlacementChecks {
    static func main() {
        var count = 0
        let displays = [
            CGRect(x: 0, y: 50, width: 1440, height: 825),
            CGRect(x: -1920, y: 40, width: 1920, height: 1016),
            CGRect(x: 1440, y: -900, width: 1280, height: 875),
            CGRect(x: 0, y: 0, width: 800, height: 380)
        ]
        for screen in displays {
            for x in [screen.minX, screen.midX, screen.maxX - 25] {
                let anchor = CGRect(x: x, y: screen.maxY, width: 50, height: 24)
                var previousTop: CGFloat?
                for height in [260.0, 480.0, 610.0, 1500.0, 300.0] {
                    let frame = quotaPanelFrame(contentSize: CGSize(width: 334, height: height), anchor: anchor, visibleFrame: screen)
                    precondition(screen.contains(frame), "Panel must remain inside the visible screen")
                    precondition(frame.maxY <= anchor.minY - 6, "Panel must open below menu bar")
                    if let previousTop { precondition(previousTop == frame.maxY, "Content changes must not move panel upward") }
                    previousTop = frame.maxY
                    count += 1
                }
            }
        }
        print("PASS: \(count) placement cases (screen edges, multi-display coordinates, short screen, dynamic heights)")
    }
}
