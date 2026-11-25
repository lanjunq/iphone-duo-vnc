import Foundation
import Testing
@testable import RFBMockServer
import RFBBase

@Suite struct SceneTests {
    func center(_ r: RFBRect) -> (Int, Int) { (r.x + r.width / 2, r.y + r.height / 2) }

    @Test func demoSceneRendersAt4KQuickly() {
        let scene = DemoDesktopScene()
        #expect(scene.pointScale == 2)
        let fb = Framebuffer(width: 3840, height: 2160)
        let t0 = Date()
        scene.render(into: fb)
        let dt = Date().timeIntervalSince(t0)
        #expect(dt < 2.0)
        // Desktop colour away from everything, menu bar colour at the top.
        let bg = fb.pixel(x: 3000, y: 1900)
        #expect(bg.red == 40 && bg.green == 90 && bg.blue == 150)
        let mb = fb.pixel(x: 1500, y: 10)
        #expect(mb.red == 236)
    }

    @Test func targetsHaveRealSizes() {
        let scene = DemoDesktopScene()
        let sizes = Set(scene.targets.filter { $0.name.hasPrefix("row") }.map { "\($0.rect.width)x\($0.rect.height)" })
        // 2 px per point.
        #expect(sizes.isSuperset(of: ["16x16", "24x24", "96x24", "120x32", "160x44", "28x28", "200x56"]))
        let lights = scene.targets.filter { $0.name.hasPrefix("light") }
        #expect(lights.count == 3 && lights.allSatisfy { $0.rect.width == 24 && $0.rect.height == 24 })
        // Targets must not overlap each other.
        let t = scene.targets
        for i in t.indices { for j in t.indices where j > i { #expect(!t[i].rect.intersects(t[j].rect), "\(t[i].name) overlaps \(t[j].name)") } }
        // All inside the screen.
        let screen = RFBRect(x: 0, y: 0, width: 3840, height: 2160)
        #expect(t.allSatisfy { screen.contains($0.rect) })
    }

    @Test func clickHitAndMiss() throws {
        let scene = DemoDesktopScene()
        let fb = Framebuffer(width: 3840, height: 2160)
        scene.render(into: fb)
        let box = try #require(scene.targets.first { $0.name == "row6:3" })   // a 14 pt checkbox
        let (cx, cy) = center(box.rect)
        let before = fb.pixel(x: box.rect.x + 8, y: box.rect.y + 8)
        let dirty = scene.pointerEvent(x: cx, y: cy, buttons: .left, framebuffer: fb)
        _ = scene.pointerEvent(x: cx, y: cy, buttons: [], framebuffer: fb)
        #expect(scene.hits == 1 && scene.misses == 0)
        #expect(scene.lastHitName == "row6:3")
        #expect(dirty.contains { $0.contains(box.rect) })
        let after = fb.pixel(x: box.rect.x + 8, y: box.rect.y + 8)
        #expect(before != after)           // checkbox filled green
        #expect(after.green == 190)

        // Edge pixels: last pixel inside is a hit, first pixel outside is a miss.
        let tiny = try #require(scene.targets.first { $0.name == "row1:1" })   // 8x8 pt = 16x16 px
        _ = scene.pointerEvent(x: tiny.rect.maxX - 1, y: tiny.rect.maxY - 1, buttons: .left, framebuffer: fb)
        _ = scene.pointerEvent(x: tiny.rect.maxX - 1, y: tiny.rect.maxY - 1, buttons: [], framebuffer: fb)
        #expect(scene.hits == 2)
        _ = scene.pointerEvent(x: tiny.rect.maxX, y: tiny.rect.y, buttons: .left, framebuffer: fb)
        _ = scene.pointerEvent(x: tiny.rect.maxX, y: tiny.rect.y, buttons: [], framebuffer: fb)
        #expect(scene.hits == 2 && scene.misses == 1)

        // Holding the button and moving does not count again.
        _ = scene.pointerEvent(x: 3000, y: 1500, buttons: .left, framebuffer: fb)
        _ = scene.pointerEvent(x: 3010, y: 1500, buttons: .left, framebuffer: fb)
        _ = scene.pointerEvent(x: 3010, y: 1500, buttons: [], framebuffer: fb)
        #expect(scene.misses == 2)

        // Right click and wheel are counted separately.
        _ = scene.pointerEvent(x: 3000, y: 1500, buttons: .right, framebuffer: fb)
        _ = scene.pointerEvent(x: 3000, y: 1500, buttons: [], framebuffer: fb)
        _ = scene.pointerEvent(x: 3000, y: 1500, buttons: .wheelDown, framebuffer: fb)
        _ = scene.pointerEvent(x: 3000, y: 1500, buttons: [], framebuffer: fb)
        #expect(scene.rightClicks == 1 && scene.wheel == [0, 1, 0, 0] && scene.misses == 2)

        // Partial redraws equal a full render of the same state.
        let full = Framebuffer(width: 3840, height: 2160)
        scene.render(into: full)
        #expect(maxDifference(fb, full) == 0)

        // RESET clears everything.
        let reset = try #require(scene.targets.first { $0.name == "reset" })
        _ = scene.pointerEvent(x: reset.rect.x + 5, y: reset.rect.y + 5, buttons: .left, framebuffer: fb)
        #expect(scene.hits == 0 && scene.misses == 0 && scene.rightClicks == 0)
        #expect(scene.targets.allSatisfy { !$0.on })
    }

    @Test func typingShowsText() {
        let scene = DemoDesktopScene()
        let fb = Framebuffer(width: 3840, height: 2160)
        scene.render(into: fb)
        func type(_ k: UInt32) {
            _ = scene.keyEvent(keysym: k, down: true, framebuffer: fb)
            _ = scene.keyEvent(keysym: k, down: false, framebuffer: fb)
        }
        _ = scene.keyEvent(keysym: 0xFFE1, down: true, framebuffer: fb)   // Shift held
        type(0x50)                                                          // P
        _ = scene.keyEvent(keysym: 0xFFE1, down: false, framebuffer: fb)
        for k in Array("a$$w0rd!".unicodeScalars) { type(k.value) }
        type(0xFF08)                                                        // BackSpace
        #expect(scene.typedText == "Pa$$w0rd")
        type(0xFF0D)
        type(0x0100_00E9 - 0x0100_0000 + 0x0100_0000)                       // é as Unicode keysym
        type(0xE9)                                                          // é as Latin-1 keysym
        type(0xFFB7)                                                        // KP_7
        #expect(scene.typedText == "Pa$$w0rd\néé7")
        let full = Framebuffer(width: 3840, height: 2160)
        scene.render(into: full)
        #expect(maxDifference(fb, full) == 0)
        type(0xFF1B)                                                        // Escape clears
        #expect(scene.typedText == "")
    }

    @Test func longTextWraps() {
        let scene = DemoDesktopScene()
        let fb = Framebuffer(width: 3840, height: 2160)
        scene.render(into: fb)
        for _ in 0..<200 { _ = scene.keyEvent(keysym: 0x78, down: true, framebuffer: fb) }
        let lines = scene.displayLines()
        #expect(lines.count == 4)
        #expect(lines.allSatisfy { $0.count <= 32 })
    }

    @Test func demoSceneSmallSizesDoNotCrash() {
        for (w, h) in [(1, 1), (320, 200), (1920, 1080), (2560, 1600), (5120, 2880)] {
            let scene = DemoDesktopScene(width: w, height: h)
            let fb = Framebuffer(width: w, height: h)
            scene.render(into: fb)
            _ = scene.pointerEvent(x: w + 100, y: h + 100, buttons: .left, framebuffer: fb)
            _ = scene.pointerEvent(x: 0, y: 0, buttons: [], framebuffer: fb)
            _ = scene.keyEvent(keysym: 0x41, down: true, framebuffer: fb)
            _ = scene.cutText(String(repeating: "x", count: 500), framebuffer: fb)
        }
    }

    @Test func demoOverServerEndToEnd() async throws {
        let h = Harness.start(.demo())
        let c = h.client
        try await withTimeout { try await c.handshake(reply: "RFB 003.889\n") }
        #expect(c.width == 3840 && c.height == 2160)
        try await c.setEncodings([RFBEncoding.tight, RFBEncoding.zrle, RFBEncoding.cursor, RFBEncoding.desktopSize])
        try await c.requestUpdate(incremental: false)
        _ = try await withTimeout(30) { try await c.readUpdate() }
        let expected = expectedFramebuffer(DemoDesktopScene(), width: 3840, height: 2160)
        #expect(maxDifference(c.decoders.fb, expected) == 0)
        let cur = try #require(c.decoders.cursor)
        #expect(cur.rect.width == 24 && cur.rect.height == 38)
        // Click the zoom traffic light and get the update.
        let light = try #require(DemoDesktopScene().targets.first { $0.name == "light:zoom" })
        try await c.pointer(x: light.rect.x + 12, y: light.rect.y + 12, buttons: .left)
        try await c.pointer(x: light.rect.x + 12, y: light.rect.y + 12, buttons: [])
        try await c.requestUpdate(incremental: true)
        let rects = try await withTimeout { try await c.readUpdate() }
        #expect(!rects.isEmpty)
        // Eventually equal to the server's state.
        var same = false
        for _ in 0..<20 {
            if maxDifference(c.decoders.fb, serverFramebuffer(h.server)!) == 0 { same = true; break }
            try await c.requestUpdate(incremental: true)
            _ = try await withTimeout { try await c.readUpdate() }
        }
        #expect(same)
        #expect(h.server.receivedEvents.isEmpty)   // demo config records nothing
        await h.finish()
    }
}
