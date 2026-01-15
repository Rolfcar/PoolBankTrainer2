import SwiftUI
import SpriteKit
import Combine

final class SceneHolder: ObservableObject {
    let scene = PoolTableScene()
}

enum InteractionMode: String, CaseIterable {
    case placeCue = "Cue"
    case placeObject = "Object"
    case selectPocket = "Pocket"
    case selectRails = "Rails"
}

struct ContentView: View {
    @State private var mode: InteractionMode = .placeCue
    @StateObject private var holder = SceneHolder()

    // Tight layout knobs
    private let topPadding: CGFloat = 44

    // Make buttons narrower
    private let leftButtonWidth: CGFloat = 60
    private let rightButtonWidth: CGFloat = 80

    // Minimal edge padding so panels sit near edges
    private let edgePad: CGFloat = 0

    // Smaller buttons
    private let buttonFont: CGFloat = 14
    private let buttonVPad: CGFloat = 8
    private let buttonCorner: CGFloat = 12
    private let stackSpacing: CGFloat = 10

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color.black.ignoresSafeArea()

                // 1) TABLE in the middle (we size it based on panel widths)
                let centerWidth = max(
                    1,
                    geo.size.width - (leftButtonWidth + rightButtonWidth) - (edgePad * 4)
                )

                SpriteView(scene: holder.scene)
                    .frame(width: centerWidth, height: geo.size.height)
                    .position(x: geo.size.width / 2, y: geo.size.height / 2)
                    .clipped()
                    .onAppear {
                        holder.scene.size = CGSize(width: centerWidth, height: geo.size.height)
                        holder.scene.scaleMode = .resizeFill
                        holder.scene.setMode(mode)
                    }
                    .onChange(of: geo.size) { _, newSize in
                        let newCenterWidth = max(
                            1,
                            newSize.width - (leftButtonWidth + rightButtonWidth) - (edgePad * 4)
                        )
                        holder.scene.size = CGSize(width: newCenterWidth, height: newSize.height)
                    }
                    .onChange(of: mode) { _, newMode in
                        holder.scene.setMode(newMode)
                    }

                // 2) LEFT PANEL pinned hard-left
                VStack(spacing: stackSpacing) {
                    ForEach(InteractionMode.allCases, id: \.self) { m in
                        Button(m.rawValue) { mode = m }
                            .font(.system(size: buttonFont, weight: .semibold))
                            .padding(.vertical, buttonVPad)
                            .frame(width: leftButtonWidth)
                            .background(mode == m ? Color.white : Color.white.opacity(0.20))
                            .foregroundColor(mode == m ? .black : .white)
                            .clipShape(RoundedRectangle(cornerRadius: buttonCorner))
                    }
                    Spacer()
                }
                .padding(.top, topPadding)
                .position(x: edgePad + leftButtonWidth / 2, y: geo.size.height / 2)

                // 3) RIGHT PANEL pinned hard-right
                VStack(spacing: stackSpacing) {
                    Button("Clear Rails") { holder.scene.clearRails() }
                        .font(.system(size: buttonFont, weight: .semibold))
                        .padding(.vertical, buttonVPad)
                        .frame(width: rightButtonWidth)
                        .background(Color.orange)
                        .foregroundColor(.black)
                        .clipShape(RoundedRectangle(cornerRadius: buttonCorner))

                    Button("Reset") { holder.scene.resetAll() }
                        .font(.system(size: buttonFont, weight: .semibold))
                        .padding(.vertical, buttonVPad)
                        .frame(width: rightButtonWidth)
                        .background(Color.white.opacity(0.20))
                        .foregroundColor(.white)
                        .clipShape(RoundedRectangle(cornerRadius: buttonCorner))

                    Button("Calibrate") { holder.scene.toggleCalibration() }
                        .font(.system(size: buttonFont, weight: .semibold))
                        .padding(.vertical, buttonVPad)
                        .frame(width: rightButtonWidth)
                        .background(Color.green.opacity(0.85))
                        .foregroundColor(.black)
                        .clipShape(RoundedRectangle(cornerRadius: buttonCorner))

                    Spacer()
                }
                .padding(.top, topPadding)
                .position(x: geo.size.width - edgePad - rightButtonWidth / 2, y: geo.size.height / 2)
            }
        }
    }
}

