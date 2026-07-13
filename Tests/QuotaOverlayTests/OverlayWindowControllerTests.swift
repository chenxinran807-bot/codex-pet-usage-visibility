import XCTest
@testable import QuotaOverlayApp

private struct ManualTracking: PetAnchorTracking { let stream:AsyncStream<PetAnchorState>; func states()->AsyncStream<PetAnchorState>{stream} }
@MainActor private final class FakePanel:OverlayPanel {
    var frame=CGRect(x:0,y:0,width:80,height:20); var shown=false; var showCount=0; var hideCount=0; var installs=0; var removals=0
    var dragBegan:(@MainActor()->Void)?; var dragEnded:(@MainActor()->Void)?; var resetRequested:(@MainActor()->Void)?
    func setFrame(_ frame:CGRect){self.frame=frame}; func show(){shown=true;showCount += 1}; func hide(){shown=false;hideCount += 1}
    func installInteractionHandlers(dragBegan:@escaping @MainActor()->Void,dragEnded:@escaping @MainActor()->Void,resetRequested:@escaping @MainActor()->Void){guard self.dragBegan == nil else{return};installs += 1;self.dragBegan=dragBegan;self.dragEnded=dragEnded;self.resetRequested=resetRequested}
    func removeInteractionHandlers(){guard dragBegan != nil else{return};removals += 1;dragBegan=nil;dragEnded=nil;resetRequested=nil}
    func setFallbackMode(_ enabled:Bool){}
}
@MainActor private final class FakePersistence:OverlayPositionPersistence {
    var point:CGPoint?
    var relativeOffset:CGPoint?
    var saves=[CGPoint]()
    var relativeSaves=[CGPoint]()
    var relativeClearCount=0
    init(_ p:CGPoint?=nil, relativeOffset:CGPoint?=nil){point=p;self.relativeOffset=relativeOffset}
    func load()->CGPoint?{point}
    func save(_ p:CGPoint){point=p;saves.append(p)}
    func loadRelativeOffset()->CGPoint?{relativeOffset}
    func saveRelativeOffset(_ p:CGPoint){relativeOffset=p;relativeSaves.append(p)}
    func clearRelativeOffset(){relativeOffset=nil;relativeClearCount += 1}
}

@MainActor final class OverlayWindowControllerTests:XCTestCase {
    func testDefaultsPersistenceKeepsRelativeOffsetSeparateFromFallbackOrigin() {
        let suiteName="OverlayWindowControllerTests.\(UUID().uuidString)"
        let defaults=UserDefaults(suiteName:suiteName)!
        defer { defaults.removePersistentDomain(forName:suiteName) }
        let persistence=DefaultsOverlayPosition(defaults)

        persistence.save(.init(x:11,y:22))
        persistence.saveRelativeOffset(.init(x:-7,y:9))

        XCTAssertEqual(persistence.load(),.init(x:11,y:22))
        XCTAssertEqual(persistence.loadRelativeOffset(),.init(x:-7,y:9))
        persistence.clearRelativeOffset()
        XCTAssertNil(persistence.loadRelativeOffset())
        XCTAssertEqual(persistence.load(),.init(x:11,y:22))
    }

    func testTransitionsPersistenceRestartAndNoPostStopUpdates() async {
        var continuation:AsyncStream<PetAnchorState>.Continuation!; let stream=AsyncStream<PetAnchorState>{continuation=$0}
        let panel=FakePanel(), persistence=FakePersistence(.init(x:30,y:40)); let controller=OverlayWindowController(panel:panel,tracker:ManualTracking(stream:stream),persistence:persistence)
        controller.start(); controller.start(); XCTAssertEqual(panel.installs,1); try? await Task.sleep(for:.milliseconds(10))
        continuation.yield(.init(codexRunning:true,petFrame:nil,visibleScreenFrames:[.init(x:0,y:0,width:300,height:200)])); try? await Task.sleep(for:.milliseconds(10))
        XCTAssertEqual(panel.frame.origin,.init(x:30,y:40)); XCTAssertTrue(panel.shown)
        panel.dragBegan?(); panel.frame.origin = .init(x:50,y:60); panel.dragEnded?(); XCTAssertEqual(persistence.point,.init(x:50,y:60))
        continuation.yield(.init(codexRunning:true,petFrame:.init(x:250,y:80,width:40,height:40),visibleScreenFrames:[.init(x:0,y:0,width:300,height:200)])); try? await Task.sleep(for:.milliseconds(10))
        XCTAssertEqual(panel.frame.origin.x,162)
        continuation.yield(.init(codexRunning:false,petFrame:nil,visibleScreenFrames:[])); try? await Task.sleep(for:.milliseconds(10)); XCTAssertFalse(panel.shown)
        continuation.yield(.init(codexRunning:true,petFrame:nil,visibleScreenFrames:[.init(x:0,y:0,width:300,height:200)])); try? await Task.sleep(for:.milliseconds(10))
        controller.stop(); controller.stop(); XCTAssertEqual(panel.removals,1); let shows=panel.showCount
        continuation.yield(.init(codexRunning:true,petFrame:nil,visibleScreenFrames:[.init(x:0,y:0,width:300,height:200)])); try? await Task.sleep(for:.milliseconds(10)); XCTAssertEqual(panel.showCount,shows)
        try? await Task.sleep(for:.milliseconds(10)); controller.start(); XCTAssertEqual(panel.installs,2); panel.dragBegan?(); panel.frame.origin = .init(x:70,y:80); panel.dragEnded?(); XCTAssertEqual(persistence.point,.init(x:70,y:80)); controller.stop()
    }

    func testSavedRelativeOffsetIsRestoredAfterControllerRestart() async {
        let pet = CGRect(x:100,y:100,width:40,height:60)
        let screens = [CGRect(x:0,y:0,width:500,height:300)]
        let persistence=FakePersistence(relativeOffset:.init(x:30,y:-10))

        var firstContinuation:AsyncStream<PetAnchorState>.Continuation!
        let firstStream=AsyncStream<PetAnchorState>{firstContinuation=$0}
        let firstPanel=FakePanel()
        let first=OverlayWindowController(panel:firstPanel,tracker:ManualTracking(stream:firstStream),persistence:persistence)
        first.start(); try? await Task.sleep(for:.milliseconds(10))
        firstContinuation.yield(.init(codexRunning:true,petFrame:pet,visibleScreenFrames:screens)); try? await Task.sleep(for:.milliseconds(10))
        let expected=OverlayPlacement.frame(pet:pet,panel:firstPanel.frame.size,screens:screens,gap:8,offset:.init(x:30,y:-10))
        XCTAssertEqual(firstPanel.frame,expected)
        first.stop()

        var secondContinuation:AsyncStream<PetAnchorState>.Continuation!
        let secondStream=AsyncStream<PetAnchorState>{secondContinuation=$0}
        let secondPanel=FakePanel()
        let second=OverlayWindowController(panel:secondPanel,tracker:ManualTracking(stream:secondStream),persistence:persistence)
        second.start(); try? await Task.sleep(for:.milliseconds(10))
        secondContinuation.yield(.init(codexRunning:true,petFrame:pet,visibleScreenFrames:screens)); try? await Task.sleep(for:.milliseconds(10))
        XCTAssertEqual(secondPanel.frame,expected)
        second.stop()
    }

    func testResetClearsRelativeOffsetAndReturnsToDefaultAnchor() async {
        var continuation:AsyncStream<PetAnchorState>.Continuation!
        let stream=AsyncStream<PetAnchorState>{continuation=$0}
        let panel=FakePanel(), persistence=FakePersistence(relativeOffset:.init(x:30,y:-10))
        let controller=OverlayWindowController(panel:panel,tracker:ManualTracking(stream:stream),persistence:persistence)
        let pet=CGRect(x:100,y:100,width:40,height:60), screens=[CGRect(x:0,y:0,width:500,height:300)]
        controller.start(); try? await Task.sleep(for:.milliseconds(10))
        continuation.yield(.init(codexRunning:true,petFrame:pet,visibleScreenFrames:screens)); try? await Task.sleep(for:.milliseconds(10))

        controller.resetRelativeOffset()

        XCTAssertNil(persistence.relativeOffset)
        XCTAssertEqual(persistence.relativeClearCount,1)
        XCTAssertEqual(panel.frame,OverlayPlacement.frame(pet:pet,panel:panel.frame.size,screens:screens,gap:8))
        controller.stop()
    }

    func testResetAfterStopClearsPersistenceWithoutReapplyingStaleState() async {
        var continuation:AsyncStream<PetAnchorState>.Continuation!
        let stream=AsyncStream<PetAnchorState>{continuation=$0}
        let panel=FakePanel(), persistence=FakePersistence(relativeOffset:.init(x:30,y:-10))
        let controller=OverlayWindowController(panel:panel,tracker:ManualTracking(stream:stream),persistence:persistence)
        controller.start(); try? await Task.sleep(for:.milliseconds(10))
        continuation.yield(.init(
            codexRunning:true,
            petFrame:.init(x:100,y:100,width:40,height:60),
            visibleScreenFrames:[.init(x:0,y:0,width:500,height:300)]
        )); try? await Task.sleep(for:.milliseconds(10))
        controller.stop()
        let stoppedFrame=panel.frame, showCount=panel.showCount

        controller.resetRelativeOffset()

        XCTAssertNil(persistence.relativeOffset)
        XCTAssertEqual(panel.frame,stoppedFrame)
        XCTAssertEqual(panel.showCount,showCount)
        XCTAssertFalse(panel.shown)
    }

    func testUserDragSavesOffsetAndPetMovementKeepsIt() async {
        var continuation:AsyncStream<PetAnchorState>.Continuation!
        let stream=AsyncStream<PetAnchorState>{continuation=$0}
        let panel=FakePanel(), persistence=FakePersistence()
        let controller=OverlayWindowController(panel:panel,tracker:ManualTracking(stream:stream),persistence:persistence)
        let screens=[CGRect(x:0,y:0,width:900,height:600)]
        let firstPet=CGRect(x:100,y:100,width:80,height:80)
        controller.start(); try? await Task.sleep(for:.milliseconds(10))
        continuation.yield(.init(codexRunning:true,petFrame:firstPet,visibleScreenFrames:screens)); try? await Task.sleep(for:.milliseconds(10))
        let defaultFrame=OverlayPlacement.frame(pet:firstPet,panel:panel.frame.size,screens:screens,gap:8)

        panel.dragBegan?()
        panel.frame.origin = .init(x:defaultFrame.minX+25,y:defaultFrame.minY-15)
        panel.dragEnded?()

        XCTAssertEqual(persistence.relativeOffset,.init(x:25,y:-15))
        let secondPet=firstPet.offsetBy(dx:40,dy:30)
        continuation.yield(.init(codexRunning:true,petFrame:secondPet,visibleScreenFrames:screens)); try? await Task.sleep(for:.milliseconds(10))
        XCTAssertEqual(panel.frame,OverlayPlacement.frame(pet:secondPet,panel:panel.frame.size,screens:screens,gap:8,offset:.init(x:25,y:-15)))
        controller.stop()
    }

    func testTrackerUpdateDuringDragDoesNotMovePanelUntilDragEnds() async {
        var continuation:AsyncStream<PetAnchorState>.Continuation!
        let stream=AsyncStream<PetAnchorState>{continuation=$0}
        let panel=FakePanel(), persistence=FakePersistence()
        let controller=OverlayWindowController(panel:panel,tracker:ManualTracking(stream:stream),persistence:persistence)
        let screens=[CGRect(x:0,y:0,width:900,height:600)]
        controller.start(); try? await Task.sleep(for:.milliseconds(10))
        continuation.yield(.init(codexRunning:true,petFrame:.init(x:100,y:100,width:80,height:80),visibleScreenFrames:screens)); try? await Task.sleep(for:.milliseconds(10))
        panel.dragBegan?()
        panel.frame.origin = .init(x:250,y:220)

        let latestPet=CGRect(x:300,y:300,width:80,height:80)
        continuation.yield(.init(codexRunning:true,petFrame:latestPet,visibleScreenFrames:screens)); try? await Task.sleep(for:.milliseconds(10))
        XCTAssertEqual(panel.frame.origin,.init(x:250,y:220))

        panel.dragEnded?()
        let defaultLatest=OverlayPlacement.frame(pet:latestPet,panel:panel.frame.size,screens:screens,gap:8)
        XCTAssertEqual(persistence.relativeOffset,.init(x:250-defaultLatest.minX,y:220-defaultLatest.minY))
        XCTAssertEqual(panel.frame,OverlayPlacement.frame(pet:latestPet,panel:panel.frame.size,screens:screens,gap:8,offset:persistence.relativeOffset!))
        controller.stop()
    }

    func testResetRequestClearsOffsetAndReturnsToDefaultAnchor() async {
        var continuation:AsyncStream<PetAnchorState>.Continuation!
        let stream=AsyncStream<PetAnchorState>{continuation=$0}
        let panel=FakePanel(), persistence=FakePersistence(relativeOffset:.init(x:30,y:-10))
        let controller=OverlayWindowController(panel:panel,tracker:ManualTracking(stream:stream),persistence:persistence)
        let pet=CGRect(x:100,y:100,width:80,height:80), screens=[CGRect(x:0,y:0,width:900,height:600)]
        controller.start(); try? await Task.sleep(for:.milliseconds(10))
        continuation.yield(.init(codexRunning:true,petFrame:pet,visibleScreenFrames:screens)); try? await Task.sleep(for:.milliseconds(10))

        panel.resetRequested?()

        XCTAssertNil(persistence.relativeOffset)
        XCTAssertEqual(panel.frame,OverlayPlacement.frame(pet:pet,panel:panel.frame.size,screens:screens,gap:8))
        controller.stop()
    }

    func testInteractionCallbacksAreRemovedAndDoNothingAfterStop() async {
        let stream=AsyncStream<PetAnchorState>{_ in}
        let panel=FakePanel(), persistence=FakePersistence(relativeOffset:.init(x:12,y:9))
        let controller=OverlayWindowController(panel:panel,tracker:ManualTracking(stream:stream),persistence:persistence)
        controller.start()
        let staleReset=panel.resetRequested, staleDragEnd=panel.dragEnded
        controller.stop()

        staleReset?(); staleDragEnd?()

        XCTAssertEqual(persistence.relativeOffset,.init(x:12,y:9))
        XCTAssertEqual(panel.removals,1)
    }
}
