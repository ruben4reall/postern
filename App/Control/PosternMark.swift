import ServiceManagement
import SwiftUI

/// Postern's symbol, from the brand's grid of 16 modules: the wall, a stone, and the arched door, closed until you
/// open it.
struct PosternMark: Shape {
    func path(in rect: CGRect) -> Path {
        let module = min(rect.width, rect.height) / 16
        let origin = CGPoint(x: rect.midX - 8 * module, y: rect.midY - 8 * module)
        func box(_ x: CGFloat, _ y: CGFloat, _ width: CGFloat, _ height: CGFloat) -> CGRect {
            CGRect(x: origin.x + x * module, y: origin.y + y * module, width: width * module, height: height * module)
        }
        var path = Path()
        path.addRect(box(1, 1, 14, 6.25))
        path.addRect(box(1, 8.75, 6.25, 6.25))
        let door = box(8.75, 8.75, 6.25, 6.25)
        let radius = door.width / 2
        path.move(to: CGPoint(x: door.minX, y: door.maxY))
        path.addLine(to: CGPoint(x: door.minX, y: door.minY + radius))
        path.addArc(center: CGPoint(x: door.midX, y: door.minY + radius), radius: radius,
                    startAngle: .degrees(180), endAngle: .degrees(360), clockwise: false)
        path.addLine(to: CGPoint(x: door.maxX, y: door.maxY))
        path.closeSubpath()
        return path
    }
}

enum SMAppServiceSettings {
    static func open() { SMAppService.openSystemSettingsLoginItems() }
}
