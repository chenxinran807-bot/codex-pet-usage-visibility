import XCTest
@testable import QuotaOverlayApp

final class OverlayPlacementTests: XCTestCase {
    func testPlacesRightAndCentered() { XCTAssertEqual(OverlayPlacement.frame(pet: .init(x: 100,y:100,width:40,height:60), panel: .init(width:80,height:20), screens:[.init(x:0,y:0,width:400,height:300)], gap: 8), .init(x:148,y:120,width:80,height:20)) }
    func testFlipsLeft() { XCTAssertEqual(OverlayPlacement.frame(pet:.init(x:350,y:100,width:40,height:60),panel:.init(width:80,height:20),screens:[.init(x:0,y:0,width:400,height:300)],gap:8).origin.x, 262) }
    func testClampsBothAxes() { XCTAssertEqual(OverlayPlacement.frame(pet:.init(x:-20,y:290,width:10,height:10),panel:.init(width:80,height:30),screens:[.init(x:0,y:0,width:400,height:300)],gap:8), .init(x:0,y:270,width:80,height:30)) }
    func testOversizedPinsToVisibleOrigin() { XCTAssertEqual(OverlayPlacement.frame(pet:.init(x:10,y:10,width:20,height:20),panel:.init(width:500,height:400),screens:[.init(x:5,y:6,width:100,height:90)],gap:8).origin, .init(x:5,y:6)) }
    func testRelativeOffsetIsAppliedThenClampedToVisibleScreen() {
        let pet = CGRect(x: 700, y: 400, width: 100, height: 100)
        let screen = CGRect(x: 0, y: 0, width: 1000, height: 700)
        let frame = OverlayPlacement.frame(
            pet: pet,
            panel: .init(width: 190, height: 62),
            screens: [screen],
            gap: 8,
            offset: .init(x: 300, y: 300)
        )
        XCTAssertEqual(frame.maxX, screen.maxX)
        XCTAssertEqual(frame.maxY, screen.maxY)
    }
    func testRelativeOffsetIsAppliedAfterDefaultPlacementHasBeenClamped() {
        let screen=CGRect(x:0,y:0,width:400,height:300)
        let frame=OverlayPlacement.frame(
            pet:.init(x:-20,y:100,width:10,height:10),
            panel:.init(width:80,height:30),
            screens:[screen],
            gap:8,
            offset:.init(x:20,y:0)
        )
        XCTAssertEqual(frame.minX,20)
    }
    func testChoosesScreenContainingCenterThenGreatestIntersection() {
        let screens = [CGRect(x:0,y:0,width:100,height:100), CGRect(x:100,y:0,width:200,height:100)]
        XCTAssertEqual(OverlayPlacement.visibleScreen(for:.init(x:130,y:10,width:20,height:20), screens:screens), screens[1])
        XCTAssertEqual(OverlayPlacement.visibleScreen(for:.init(x:90,y:10,width:30,height:20), screens:screens), screens[1])
    }
    func testFallbackClampsStaleRemoteOversizedAndKeepsValid() {
        let screens=[CGRect(x:0,y:0,width:300,height:200),CGRect(x:300,y:0,width:200,height:200)]
        XCTAssertEqual(OverlayPlacement.fallbackFrame(savedOrigin:.init(x:-500,y:-300),panel:.init(width:80,height:30),screens:screens),.init(x:0,y:0,width:80,height:30))
        XCTAssertEqual(OverlayPlacement.fallbackFrame(savedOrigin:.init(x:900,y:50),panel:.init(width:80,height:30),screens:screens),.init(x:420,y:50,width:80,height:30))
        XCTAssertEqual(OverlayPlacement.fallbackFrame(savedOrigin:.init(x:40,y:50),panel:.init(width:400,height:300),screens:screens),.init(x:0,y:0,width:400,height:300))
        XCTAssertEqual(OverlayPlacement.fallbackFrame(savedOrigin:.init(x:330,y:50),panel:.init(width:80,height:30),screens:screens),.init(x:330,y:50,width:80,height:30))
    }
    func testGripReducerSeparatesClickAndDrag() {
        var reducer=FallbackGripInteraction(threshold:4)
        XCTAssertEqual(reducer.handle(.down(.zero)),.none)
        XCTAssertEqual(reducer.handle(.up(.init(x:2,y:1))),.none)
        XCTAssertEqual(reducer.handle(.down(.zero)),.none)
        XCTAssertEqual(reducer.handle(.moved(.init(x:5,y:0))),.beginDrag)
        XCTAssertEqual(reducer.handle(.up(.init(x:8,y:0))),.endDrag)
    }

    func testPanelInteractionRequiresThresholdBeforeDragAndDefersSingleClick() {
        var interaction=PanelInteractionReducer(threshold:4)
        XCTAssertEqual(interaction.handle(.mouseDown(point:.zero,clickCount:1)),[])
        XCTAssertEqual(interaction.handle(.mouseMoved(.init(x:3,y:0))),[])
        XCTAssertEqual(interaction.handle(.mouseUp),[.scheduleSingleClick])
        XCTAssertEqual(interaction.handle(.singleClickDelayElapsed),[.singleClick])

        XCTAssertEqual(interaction.handle(.mouseDown(point:.zero,clickCount:1)),[])
        XCTAssertEqual(interaction.handle(.mouseMoved(.init(x:4,y:0))),[.dragBegan])
        XCTAssertEqual(interaction.handle(.mouseUp),[.dragEnded])
        XCTAssertEqual(interaction.handle(.singleClickDelayElapsed),[])
    }

    func testPanelInteractionCancelsDeferredSingleClickWhenDoubleClickResets() {
        var interaction=PanelInteractionReducer(threshold:4)
        XCTAssertEqual(interaction.handle(.mouseDown(point:.zero,clickCount:1)),[])
        XCTAssertEqual(interaction.handle(.mouseUp),[.scheduleSingleClick])

        XCTAssertEqual(
            interaction.handle(.mouseDown(point:.zero,clickCount:2)),
            [.cancelSingleClick,.resetRequested]
        )
        XCTAssertEqual(interaction.handle(.singleClickDelayElapsed),[])
        XCTAssertEqual(interaction.handle(.mouseUp),[])
    }
}
