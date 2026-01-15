import SpriteKit
import UIKit

final class PoolTableScene: SKScene {

    // MARK: - Calibration State
    private var isCalibrating = false
    private var calibrationLayer = SKNode()
    private var draggingNode: SKNode?

    // MARK: - Table Geometry State
    private var currentTableRect: CGRect = .zero

    private struct CalibGeometry: Codable {
        var playfieldInset: CGFloat          // fallback if rails not calibrated
        var pocketRadius: CGFloat
        var pockets: [String: CGPoint]       // normalized (0..1 in tableRect)

        // Rail line calibration (normalized to tableRect)
        var railTopY: CGFloat?
        var railBottomY: CGFloat?
        var railLeftX: CGFloat?
        var railRightX: CGFloat?
    }

    private var calib = CalibGeometry(
        playfieldInset: 0.085,
        pocketRadius: 0.045,
        pockets: [:]
    )

    private let calibKey = "PoolBankTrainer.Calibration.v1"
    private let debugLabel = SKLabelNode(fontNamed: "Menlo-Bold")

    private func loadCalibration() {
        guard let data = UserDefaults.standard.data(forKey: calibKey) else { return }
        if let decoded = try? JSONDecoder().decode(CalibGeometry.self, from: data) {
            calib = decoded
        }
    }


    private func saveCalibration() {
        if let data = try? JSONEncoder().encode(calib) {
            UserDefaults.standard.set(data, forKey: calibKey)
        }
    }
    private func seedRailCalibrationIfNeeded() {
        // If any are missing, seed all 4 from current playfieldRect
        if calib.railTopY == nil || calib.railBottomY == nil || calib.railLeftX == nil || calib.railRightX == nil {
            guard currentTableRect.width > 0, currentTableRect.height > 0 else { return }

            let leftX = (playfieldRect.minX - currentTableRect.minX) / currentTableRect.width
            let rightX = (playfieldRect.maxX - currentTableRect.minX) / currentTableRect.width
            let bottomY = (playfieldRect.minY - currentTableRect.minY) / currentTableRect.height
            let topY = (playfieldRect.maxY - currentTableRect.minY) / currentTableRect.height

            calib.railLeftX = max(0, min(1, leftX))
            calib.railRightX = max(0, min(1, rightX))
            calib.railBottomY = max(0, min(1, bottomY))
            calib.railTopY = max(0, min(1, topY))

            saveCalibration()
        }
    }

    // MARK: - Public hooks
    var onRequestHaptic: (() -> Void)?

    // MARK: - Model / State
    private(set) var mode: InteractionMode = .placeCue

    private var cueBallNode: SKShapeNode!
    private var objectBallNode: SKShapeNode!

    private var selectedPocketId: PocketId?
    private var selectedRails: [RailId] = []

    // Overlays
    private var cueLineNode = SKShapeNode()
    private var objectPathNode = SKShapeNode()
    private var pocketHighlightNode: SKShapeNode?


    // Table nodes
    private var tableRoot = SKNode()
    private var railNodes: [RailId: SKShapeNode] = [:]
    private var diamondNodes: [SKShapeNode] = []

    // Geometry
    private var playfieldRect: CGRect = .zero
    private var cushionThickness: CGFloat = 0
    private var ballRadius: CGFloat = 0
    private var pocketRadius: CGFloat = 0

    private var railSegments: [RailId: (p0: CGPoint, p1: CGPoint)] = [:]
    private var pocketCenters: [PocketId: CGPoint] = [:]

    // MARK: - IDs
    enum PocketId: CaseIterable { case tl, tm, tr, bl, bm, br }
    enum RailId: CaseIterable { case top, bottom, left, right }

    // MARK: - Assets
    private let bgImageName = "pool_table_bg"
    private var bgTextureSize: CGSize = .zero
    private var backgroundSprite: SKSpriteNode?

    // MARK: - Lifecycle
    override func didMove(to view: SKView) {
        loadCalibration()

        backgroundColor = .black
        if tableRoot.parent == nil { addChild(tableRoot) }
        if calibrationLayer.parent == nil { addChild(calibrationLayer) }

        cueLineNode.strokeColor = .white.withAlphaComponent(0.75)
        cueLineNode.lineWidth = 2
        cueLineNode.zPosition = 50
        if cueLineNode.parent == nil { addChild(cueLineNode) }

        objectPathNode.strokeColor = .yellow.withAlphaComponent(0.85)
        objectPathNode.lineWidth = 3
        objectPathNode.zPosition = 50
        if objectPathNode.parent == nil { addChild(objectPathNode) }

        ensureBallNodesExist()

        layoutTable()
        placeDefaultBallsIfNeeded()
        renderAll()
        
        debugLabel.fontSize = 18
        debugLabel.fontColor = .white
        debugLabel.horizontalAlignmentMode = .left
        debugLabel.verticalAlignmentMode = .top
        debugLabel.position = CGPoint(x: 18, y: size.height - 18)
        debugLabel.zPosition = 999
        updateDebugLabel()
        if debugLabel.parent == nil { addChild(debugLabel) }


    }
    private func updatePocketHighlight() {
        // Remove if nothing selected
        guard let id = selectedPocketId, let c = pocketCenters[id] else {
            pocketHighlightNode?.removeFromParent()
            pocketHighlightNode = nil
            return
        }

        // Make (or rebuild) the ring
        pocketHighlightNode?.removeFromParent()

        let r = pocketRadius * 1.15  // slightly larger than hit radius
        let ring = SKShapeNode(circleOfRadius: r)
        ring.position = c
        ring.fillColor = .clear
        ring.strokeColor = UIColor.systemYellow.withAlphaComponent(0.95)
        ring.lineWidth = 4
        ring.glowWidth = 6
        ring.zPosition = 200  // above table image, below calibration overlay
        ring.name = "pocketHighlight"

        addChild(ring)
        pocketHighlightNode = ring
    }

    
    private func updateDebugLabel() {
        debugLabel.text = isCalibrating ? "CALIBRATING: ON" : "CALIBRATING: OFF"
    }

    override func didChangeSize(_ oldSize: CGSize) {
        super.didChangeSize(oldSize)
        ensureBallNodesExist()
        layoutTable()
        placeDefaultBallsIfNeeded()
        renderAll()
        
        debugLabel.position = CGPoint(x: 18, y: size.height - 18)
        updateDebugLabel()

    }

    // MARK: - Public API
    func setMode(_ mode: InteractionMode) {
        self.mode = mode
    }

    func clearRails() {
        selectedRails.removeAll()
        clearOverlays()
        updateHighlights()
        onRequestHaptic?()
    }

    func resetAll() {
        selectedPocketId = nil
        updatePocketHighlight()

        selectedRails.removeAll()

        placeCueBall(at: CGPoint(x: playfieldRect.midX - playfieldRect.width * 0.25, y: playfieldRect.midY))
        placeObjectBall(at: CGPoint(x: playfieldRect.midX, y: playfieldRect.midY))

        clearOverlays()
        updateHighlights()
        onRequestHaptic?()
    }

    // MARK: - Calibration overlay
    private let pocketKeys: [PocketId: String] = [
        .tl: "tl", .tm: "tm", .tr: "tr",
        .bl: "bl", .bm: "bm", .br: "br"
    ]

    private func renderCalibrationOverlay() {
        calibrationLayer.removeAllChildren()
        guard isCalibrating else { return }

        // playfield outline
        let outline = SKShapeNode(rect: playfieldRect)
        outline.strokeColor = .magenta
        outline.lineWidth = 3
        outline.fillColor = .clear
        outline.zPosition = 500
        calibrationLayer.addChild(outline)

        // rail handles
        func railHandle(name: String, pos: CGPoint, horizontal: Bool) {
            let size = horizontal ? CGSize(width: 44, height: 12) : CGSize(width: 12, height: 44)
            let h = SKShapeNode(rectOf: size, cornerRadius: 4)
            h.position = pos
            h.fillColor = UIColor.systemGreen.withAlphaComponent(0.35)
            h.strokeColor = .systemGreen
            h.lineWidth = 3
            h.zPosition = 520
            h.name = "calibRail:\(name)"
            calibrationLayer.addChild(h)
        }

        railHandle(name: "top",    pos: CGPoint(x: playfieldRect.midX, y: playfieldRect.maxY), horizontal: true)
        railHandle(name: "bottom", pos: CGPoint(x: playfieldRect.midX, y: playfieldRect.minY), horizontal: true)
        railHandle(name: "left",   pos: CGPoint(x: playfieldRect.minX, y: playfieldRect.midY), horizontal: false)
        railHandle(name: "right",  pos: CGPoint(x: playfieldRect.maxX, y: playfieldRect.midY), horizontal: false)

        // pocket handles (magenta)
        for (pid, key) in pocketKeys {
            guard let center = pocketCenters[pid] else { continue }
            let handle = SKShapeNode(circleOfRadius: 18)
            handle.position = center
            handle.fillColor = UIColor.magenta.withAlphaComponent(0.25)
            handle.strokeColor = .magenta
            handle.lineWidth = 3
            handle.zPosition = 510
            handle.name = "calib:\(key)"
            calibrationLayer.addChild(handle)
        }
    }

    func toggleCalibration() {
        isCalibrating.toggle()
        draggingNode = nil

        // Always re-layout before drawing calibration overlay
        layoutTable()

        if !isCalibrating {
            calibrationLayer.removeAllChildren()
        } else {
            // Seed rails if needed so handles actually drive playfieldRect
            seedRailCalibrationIfNeeded()
        }

        clearOverlays()
        updateHighlights()
        renderCalibrationOverlay()
        updateDebugLabel()
        onRequestHaptic?()
    }

    func isInCalibrationMode() -> Bool { isCalibrating }

    // MARK: - Touches
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let t = touches.first else { return }
        if isCalibrating {
            let p = t.location(in: self)
            draggingNode = nodes(at: p).first {
                ($0.name?.hasPrefix("calib:") == true) || ($0.name?.hasPrefix("calibRail:") == true)
            }
        }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard isCalibrating, let t = touches.first, let node = draggingNode, let name = node.name else { return }
        let p = t.location(in: self)

        if name.hasPrefix("calibRail:") {
            // constrain motion by axis
            if name.contains(":top") || name.contains(":bottom") {
                node.position = CGPoint(x: node.position.x, y: p.y)
            } else {
                node.position = CGPoint(x: p.x, y: node.position.y)
            }
        } else {
            node.position = p
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let t = touches.first else { return }

        // calibration commit
        if isCalibrating {
            guard let node = draggingNode, let name = node.name else {
                draggingNode = nil
                return
            }

            let p = node.position
            let nx = (p.x - currentTableRect.minX) / currentTableRect.width
            let ny = (p.y - currentTableRect.minY) / currentTableRect.height

            if name.hasPrefix("calib:") {
                if let key = name.split(separator: ":").last {
                    calib.pockets[String(key)] = CGPoint(x: max(0, min(1, nx)), y: max(0, min(1, ny)))
                }
            } else if name.hasPrefix("calibRail:") {
                if let key = name.split(separator: ":").last {
                    switch key {
                    case "top":    calib.railTopY = max(0, min(1, ny))
                    case "bottom": calib.railBottomY = max(0, min(1, ny))
                    case "left":   calib.railLeftX = max(0, min(1, nx))
                    case "right":  calib.railRightX = max(0, min(1, nx))
                    default: break
                    }
                }
            }

            draggingNode = nil
            saveCalibration()
            layoutTable()
            renderCalibrationOverlay()
            placeDefaultBallsIfNeeded()
            renderAll()
            return
        }

        // normal input
        let p = t.location(in: self)
        switch mode {
        case .placeCue:
            placeCueBall(at: p)
            recomputeShotIfPossible()

        case .placeObject:
            placeObjectBall(at: p)
            recomputeShotIfPossible()

        case .selectPocket:
            if let hitPocket = hitTestPocket(at: p) {
                selectedPocketId = hitPocket
                onRequestHaptic?()
                updateHighlights()
                recomputeShotIfPossible()
            }

        case .selectRails:
            if let hitRail = hitTestRail(at: p) {
                toggleRailSelection(hitRail)
                onRequestHaptic?()
                updateHighlights()
                recomputeShotIfPossible()
            }
        }
    }

    // MARK: - Nodes
    private func ensureBallNodesExist() {
        if cueBallNode == nil || objectBallNode == nil {
            createBallNodes()
        }
    }

    private func createBallNodes() {
        if cueBallNode == nil {
            cueBallNode = makeBallNode(fill: .white, stroke: UIColor(white: 0.75, alpha: 1))
            cueBallNode.zPosition = 30
            addChild(cueBallNode)
        }
        if objectBallNode == nil {
            objectBallNode = makeBallNode(
                fill: UIColor(red: 0.95, green: 0.25, blue: 0.15, alpha: 1),
                stroke: UIColor(white: 0.15, alpha: 1)
            )
            objectBallNode.zPosition = 30
            addChild(objectBallNode)
        }
    }

    private func makeBallNode(fill: UIColor, stroke: UIColor) -> SKShapeNode {
        let n = SKShapeNode(circleOfRadius: ballRadius > 0 ? ballRadius : 10)
        n.fillColor = fill
        n.strokeColor = stroke
        n.lineWidth = 2
        return n
    }

    private func resizeBallNodesIfNeeded() {
        guard cueBallNode != nil, objectBallNode != nil else { return }
        cueBallNode.path = CGPath(ellipseIn: CGRect(x: -ballRadius, y: -ballRadius,
                                                   width: 2*ballRadius, height: 2*ballRadius), transform: nil)
        objectBallNode.path = CGPath(ellipseIn: CGRect(x: -ballRadius, y: -ballRadius,
                                                      width: 2*ballRadius, height: 2*ballRadius), transform: nil)
    }

    // MARK: - Layout
    private func layoutTable() {
        tableRoot.removeAllChildren()
        railNodes.removeAll()
        diamondNodes.removeAll()

        // 1) margins
        let screenInset: CGFloat = 0
        let available = CGRect(x: screenInset, y: screenInset,
                               width: size.width - 2*screenInset,
                               height: size.height - 2*screenInset)

        // 2) texture size
        let texture = SKTexture(imageNamed: bgImageName)
        let texSize = texture.size()
        if texSize.width > 0 { bgTextureSize = texSize }

        // 3) aspect-fit tableRect
        let imgAspect = bgTextureSize.width / max(bgTextureSize.height, 1)
        let availAspect = available.width / max(available.height, 1)

        let tableRect: CGRect
        if availAspect > imgAspect {
            let w = available.height * imgAspect
            tableRect = CGRect(x: available.midX - w/2, y: available.minY, width: w, height: available.height)
        } else {
            let h = available.width / imgAspect
            tableRect = CGRect(x: available.minX, y: available.midY - h/2, width: available.width, height: h)
        }

        currentTableRect = tableRect

        // 4) playfield rect
        let minDim = min(tableRect.width, tableRect.height)

        if let topY = calib.railTopY,
           let botY = calib.railBottomY,
           let leftX = calib.railLeftX,
           let rightX = calib.railRightX {

            let left = tableRect.minX + leftX * tableRect.width
            let right = tableRect.minX + rightX * tableRect.width
            let top = tableRect.minY + topY * tableRect.height
            let bottom = tableRect.minY + botY * tableRect.height

            playfieldRect = CGRect(x: left, y: bottom, width: right - left, height: top - bottom)
            cushionThickness = max(10, minDim * 0.06)

        } else {
            let insetPx = minDim * calib.playfieldInset
            playfieldRect = tableRect.insetBy(dx: insetPx, dy: insetPx)     // ✅ FIXED
            cushionThickness = insetPx
        }

        // 5) pocket defaults + centers
        func ensurePocket(_ key: String, _ p: CGPoint) {
            if calib.pockets[key] == nil { calib.pockets[key] = p }
        }

        ensurePocket("tl", CGPoint(x: 0.08, y: 0.92))
        ensurePocket("tm", CGPoint(x: 0.50, y: 0.93))
        ensurePocket("tr", CGPoint(x: 0.92, y: 0.92))
        ensurePocket("bl", CGPoint(x: 0.08, y: 0.08))
        ensurePocket("bm", CGPoint(x: 0.50, y: 0.07))
        ensurePocket("br", CGPoint(x: 0.92, y: 0.08))

        func normToScene(_ n: CGPoint) -> CGPoint {
            CGPoint(x: tableRect.minX + n.x * tableRect.width,
                    y: tableRect.minY + n.y * tableRect.height)
        }

        pocketCenters[.tl] = normToScene(calib.pockets["tl"]!)
        pocketCenters[.tm] = normToScene(calib.pockets["tm"]!)
        pocketCenters[.tr] = normToScene(calib.pockets["tr"]!)
        pocketCenters[.bl] = normToScene(calib.pockets["bl"]!)
        pocketCenters[.bm] = normToScene(calib.pockets["bm"]!)
        pocketCenters[.br] = normToScene(calib.pockets["br"]!)

        // 6) sizes
        pocketRadius = minDim * calib.pocketRadius
        ballRadius = min(playfieldRect.width, playfieldRect.height) * 0.0265
        resizeBallNodesIfNeeded()

        // 7) rail segments (edges of playfield)
        railSegments[.top] = (CGPoint(x: playfieldRect.minX, y: playfieldRect.maxY),
                              CGPoint(x: playfieldRect.maxX, y: playfieldRect.maxY))
        railSegments[.bottom] = (CGPoint(x: playfieldRect.minX, y: playfieldRect.minY),
                                 CGPoint(x: playfieldRect.maxX, y: playfieldRect.minY))
        railSegments[.left] = (CGPoint(x: playfieldRect.minX, y: playfieldRect.minY),
                               CGPoint(x: playfieldRect.minX, y: playfieldRect.maxY))
        railSegments[.right] = (CGPoint(x: playfieldRect.maxX, y: playfieldRect.minY),
                                CGPoint(x: playfieldRect.maxX, y: playfieldRect.maxY))

        // 8) draw
        drawBackgroundImage(in: tableRect)
        
        drawRailsHitTargets()
        renderCalibrationOverlay()
    }

    private func drawBackgroundImage(in tableRect: CGRect) {
        backgroundSprite?.removeFromParent()

        let sprite = SKSpriteNode(imageNamed: bgImageName)
        sprite.zPosition = -10
        sprite.position = CGPoint(x: tableRect.midX, y: tableRect.midY)
        sprite.size = tableRect.size

        tableRoot.addChild(sprite)
        backgroundSprite = sprite
    }

    private func drawRailsHitTargets() {
        let thickness = max(12, cushionThickness * 0.65)

        let topRect = CGRect(x: playfieldRect.minX, y: playfieldRect.maxY - thickness,
                             width: playfieldRect.width, height: thickness)
        let bottomRect = CGRect(x: playfieldRect.minX, y: playfieldRect.minY,
                                width: playfieldRect.width, height: thickness)
        let leftRect = CGRect(x: playfieldRect.minX, y: playfieldRect.minY,
                              width: thickness, height: playfieldRect.height)
        let rightRect = CGRect(x: playfieldRect.maxX - thickness, y: playfieldRect.minY,
                               width: thickness, height: playfieldRect.height)

        let specs: [(RailId, CGRect)] = [(.top, topRect), (.bottom, bottomRect), (.left, leftRect), (.right, rightRect)]

        for (rail, rect) in specs {
            let r = SKShapeNode(rect: rect)
            r.fillColor = UIColor.white.withAlphaComponent(0.001) // invisible hit target
            r.strokeColor = .clear
            r.zPosition = 20
            r.name = "rail:\(rail)"
            tableRoot.addChild(r)
            railNodes[rail] = r
        }
    }

    private func drawDiamonds() {
        func addDiamond(at p: CGPoint) {
            let d = SKShapeNode(rectOf: CGSize(width: max(6, ballRadius * 0.65),
                                              height: max(6, ballRadius * 0.65)))
            d.position = p
            d.zRotation = .pi / 4
            d.fillColor = UIColor.white.withAlphaComponent(0.85)
            d.strokeColor = .clear
            d.zPosition = 15
            tableRoot.addChild(d)
            diamondNodes.append(d)
        }

        let insetFromEdge = cushionThickness * 0.35

        for i in 1...3 {
            let x = playfieldRect.minX + playfieldRect.width * (CGFloat(i) / 4.0)
            addDiamond(at: CGPoint(x: x, y: playfieldRect.maxY + insetFromEdge))
            addDiamond(at: CGPoint(x: x, y: playfieldRect.minY - insetFromEdge))
        }

        for i in 1...2 {
            let y = playfieldRect.minY + playfieldRect.height * (CGFloat(i) / 3.0)
            addDiamond(at: CGPoint(x: playfieldRect.minX - insetFromEdge, y: y))
            addDiamond(at: CGPoint(x: playfieldRect.maxX + insetFromEdge, y: y))
        }
    }

    // MARK: - Balls placement
    private func placeDefaultBallsIfNeeded() {
        resizeBallNodesIfNeeded()

        if cueBallNode.position == .zero && objectBallNode.position == .zero {
            resetAll()
        } else {
            cueBallNode.position = nearestLegalPoint(for: cueBallNode.position, placingCue: true)
            objectBallNode.position = nearestLegalPoint(for: objectBallNode.position, placingCue: false)
        }
    }

    private func placeCueBall(at scenePoint: CGPoint) {
        cueBallNode.position = nearestLegalPoint(for: scenePoint, placingCue: true)
    }

    private func placeObjectBall(at scenePoint: CGPoint) {
        objectBallNode.position = nearestLegalPoint(for: scenePoint, placingCue: false)
    }

    private func nearestLegalPoint(for desired: CGPoint, placingCue: Bool) -> CGPoint {
        var p = CGPoint(
            x: clamp(desired.x, playfieldRect.minX + ballRadius, playfieldRect.maxX - ballRadius),
            y: clamp(desired.y, playfieldRect.minY + ballRadius, playfieldRect.maxY - ballRadius)
        )

        for (_, c) in pocketCenters {
            let minDist = pocketRadius + ballRadius * 0.9
            let v = p - c
            let d = v.length
            if d < minDist, d > 0.001 {
                p = c + v.normalized * minDist
            }
        }

        let other = placingCue ? objectBallNode.position : cueBallNode.position
        if other != .zero {
            let minDist = 2 * ballRadius
            let v = p - other
            let d = v.length
            if d < minDist, d > 0.001 {
                p = other + v.normalized * minDist
            }
        }

        p.x = clamp(p.x, playfieldRect.minX + ballRadius, playfieldRect.maxX - ballRadius)
        p.y = clamp(p.y, playfieldRect.minY + ballRadius, playfieldRect.maxY - ballRadius)
        return p
    }

    // MARK: - Hit testing
    private func hitTestPocket(at point: CGPoint) -> PocketId? {
        for (id, c) in pocketCenters {
            if (point - c).length <= pocketRadius * 1.15 { return id }
        }
        return nil
    }

    private func hitTestRail(at point: CGPoint) -> RailId? {
        let nodesAtPoint = nodes(at: point)
        for n in nodesAtPoint {
            if let name = n.name, name.hasPrefix("rail:") {
                if name.contains("top") { return .top }
                if name.contains("bottom") { return .bottom }
                if name.contains("left") { return .left }
                if name.contains("right") { return .right }
            }
        }
        return nil
    }

    private func inwardNormal(for rail: RailId) -> CGPoint {
        switch rail {
        case .top:
            return CGPoint(x: 0, y: -1)
        case .bottom:
            return CGPoint(x: 0, y: 1)
        case .left:
            return CGPoint(x: 1, y: 0)
        case .right:
            return CGPoint(x: -1, y: 0)
        }
    }

    
    private func toggleRailSelection(_ rail: RailId) {
        if let idx = selectedRails.firstIndex(of: rail) {
            selectedRails.remove(at: idx)
        } else {
            if selectedRails.count < 3 { selectedRails.append(rail) }
        }
    }

    // MARK: - Highlights & overlays
    private func updateHighlights() {
        for (rail, node) in railNodes {
            if let order = selectedRails.firstIndex(of: rail) {
                let a: CGFloat = 0.10 + CGFloat(order) * 0.05
                node.fillColor = UIColor.yellow.withAlphaComponent(a)
            } else {
                node.fillColor = UIColor.white.withAlphaComponent(0.001)
            }
        }
        
        updatePocketHighlight()

    }

    private func renderAll() {
        updateHighlights()
        recomputeShotIfPossible()
    }

    private func recomputeShotIfPossible() {
        clearOverlays()

        guard let pocketId = selectedPocketId else { return }
        guard !selectedRails.isEmpty else { return }
        guard let P = pocketCenters[pocketId] else { return }

        let C = cueBallNode.position
        let O = objectBallNode.position

        if selectedRails.count == 1 {
            let railId = selectedRails[0]
            guard let railSeg = railSegments[railId] else { return }

            if let result = GeometryEngine.singleRailBank(objectBall: O, pocket: P, rail: railSeg) {

                // ✅ realism filter: must approach rail, then leave back into table
                let n = self.inwardNormal(for: railId).normalized
                let vIn  = (result.bouncePoint - O).normalized          // O -> bounce
                let vOut = (P - result.bouncePoint).normalized          // bounce -> pocket

                // approaching rail means moving *against* inward normal (dot < 0)
                let approachesRail = vIn.dot(n) < -0.02

                // leaving rail means moving *with* inward normal (dot > 0)
                let leavesIntoTable = vOut.dot(n) > 0.02

                guard approachesRail, leavesIntoTable else {
                    // Invalid / "backwards" / through-cushion shot → show nothing
                    return
                }

                // (Optional) reject super-shallow “skimming” banks
                // let minAngle = 0.03
                // guard abs(vIn.dot(n)) > minAngle, abs(vOut.dot(n)) > minAngle else { return }

                objectPathNode.path = makePolylinePath(points: [O, result.bouncePoint, P])

                let dir = (result.bouncePoint - O).normalized
                let ghost = O - dir * (2 * ballRadius)
                cueLineNode.path = makePolylinePath(points: [C, ghost])

            }
        }

    }

    private func clearOverlays() {
        cueLineNode.path = nil
        objectPathNode.path = nil
    }

    private func makePolylinePath(points: [CGPoint]) -> CGPath? {
        guard points.count >= 2 else { return nil }
        let p = CGMutablePath()
        p.move(to: points[0])
        for i in 1..<points.count { p.addLine(to: points[i]) }
        return p
    }

    private func clamp(_ v: CGFloat, _ lo: CGFloat, _ hi: CGFloat) -> CGFloat {
        min(max(v, lo), hi)
    }
}

// MARK: - Geometry Engine
enum GeometryEngine {
    static func singleRailBank(objectBall O: CGPoint, pocket P: CGPoint,
                               rail: (p0: CGPoint, p1: CGPoint)) -> (bouncePoint: CGPoint, reflectedPocket: CGPoint)? {
        let A = rail.p0
        let B = rail.p1
        guard let Pm = reflect(point: P, overLineThrough: A, and: B) else { return nil }
        guard let I = intersectLineSegmentWithInfiniteLineRay(from: O, to: Pm, segmentA: A, segmentB: B) else { return nil }
        return (bouncePoint: I, reflectedPocket: Pm)
    }

    static func reflect(point P: CGPoint, overLineThrough A: CGPoint, and B: CGPoint) -> CGPoint? {
        let AB = B - A
        let abLen2 = AB.dot(AB)
        if abLen2 < 1e-6 { return nil }
        let AP = P - A
        let t = AP.dot(AB) / abLen2
        let proj = A + AB * t
        return proj * 2 - P
    }

    static func intersectLineSegmentWithInfiniteLineRay(from O: CGPoint, to T: CGPoint,
                                                        segmentA A: CGPoint, segmentB B: CGPoint) -> CGPoint? {
        let r = T - O
        let s = B - A
        let denom = r.cross(s)
        if abs(denom) < 1e-6 { return nil }

        let u = (A - O).cross(r) / denom
        let t = (A - O).cross(s) / denom

        if u >= 0 && u <= 1 && t >= 0 { return O + r * t }
        return nil
    }
    


}

// MARK: - CGPoint math
private extension CGPoint {
    static func + (l: CGPoint, r: CGPoint) -> CGPoint { CGPoint(x: l.x + r.x, y: l.y + r.y) }
    static func - (l: CGPoint, r: CGPoint) -> CGPoint { CGPoint(x: l.x - r.x, y: l.y - r.y) }
    static func * (l: CGPoint, r: CGFloat) -> CGPoint { CGPoint(x: l.x * r, y: l.y * r) }
    static func * (l: CGFloat, r: CGPoint) -> CGPoint { CGPoint(x: l * r.x, y: l * r.y) }

    var length: CGFloat { sqrt(x*x + y*y) }
    var normalized: CGPoint {
        let len = length
        return len < 1e-6 ? .zero : self * (1.0 / len)
    }
    func dot(_ o: CGPoint) -> CGFloat { x*o.x + y*o.y }
    func cross(_ o: CGPoint) -> CGFloat { x*o.y - y*o.x }
}

//
//  PoolTableScene.swift
//  PoolBankTrainer
//
//  Created by Rolf Carlson on 1/1/26.
//

