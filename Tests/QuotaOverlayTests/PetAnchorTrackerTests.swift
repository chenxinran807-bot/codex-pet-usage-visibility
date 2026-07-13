import XCTest
@testable import QuotaOverlayApp

private actor SnapshotSource:PetWindowSourcing { var values:[PetWindowSnapshot]; var calls=0; init(_ values:[PetWindowSnapshot]){self.values=values}; func snapshot()->PetWindowSnapshot{defer{calls += 1};return values[min(calls,values.count-1)]} }
private actor TerminationCount { var value=0; func increment(){value += 1} }
private struct ManualTicker:PetAnchorTicking { let stream:AsyncStream<Void>; func ticks()->AsyncStream<Void>{stream} }
private actor AsyncGate {
    private var open=false; private var waiters:[CheckedContinuation<Void,Never>]=[]
    func signal(){guard !open else{return};open=true;waiters.forEach{$0.resume()};waiters.removeAll()}
    func wait() async { if open{return}; await withCheckedContinuation{waiters.append($0)} }
}

final class PetAnchorTrackerTests: XCTestCase {
    func testSelectionNeverAnchorsToQuotaOverlayOwnWindow() {
        let ownPanel = PetWindow(
            owner: "Codex Pet Quota",
            bundleID: "com.chenxinran.codexpetquota",
            title: "",
            frame: .init(x: 100, y: 100, width: 190, height: 62),
            layer: 3,
            onScreen: true,
            windowID: 99
        )

        XCTAssertNil(PetAnchorSelection.select(from: [ownPanel]))
    }

    func testSelectsCurrentLargePetInsteadOfTinyCodexAccessoryWindow() {
        let accessory = PetWindow(owner: "ChatGPT", bundleID: "com.openai.codex", title: "", frame: .init(x: 943, y: 0, width: 34, height: 37), layer: 25, onScreen: true, windowID: 1)
        let pet = PetWindow(owner: "ChatGPT", bundleID: "com.openai.codex", title: "", frame: .init(x: 1083, y: 36, width: 356, height: 320), layer: 3, onScreen: true, windowID: 2)

        XCTAssertEqual(PetAnchorSelection.select(from: [accessory, pet])?.windowID, pet.windowID)
    }

    func testUniqueCandidateAndDuplicateMetadataSelectOnce() {
        let windows = [
            PetWindow(owner:"Codex", bundleID:"com.openai.codex", title:"", frame:.init(x:0,y:0,width:1200,height:800), layer:0, onScreen:true, windowID:1),
            PetWindow(owner:"Other", bundleID:"x", title:"", frame:.init(x:0,y:0,width:100,height:100), layer:5, onScreen:true, windowID:2),
            PetWindow(owner:"Codex", bundleID:"com.openai.codex", title:"", frame:.init(x:4,y:5,width:96,height:96), layer:3, onScreen:true, windowID:4),
            PetWindow(owner:"Codex", bundleID:"com.openai.codex", title:"", frame:.init(x:4,y:5,width:96,height:96), layer:3, onScreen:true, windowID:3)]
        XCTAssertEqual(PetAnchorSelection.select(from: windows)?.windowID, 3)
    }
    func testExplicitPetTitleWinsAndAmbiguousCandidatesReturnNil() {
        let a=PetWindow(owner:"Codex",bundleID:"com.openai.codex",title:"helper",frame:.init(x:1,y:1,width:90,height:90),layer:2,onScreen:true,windowID:1)
        let b=PetWindow(owner:"Codex",bundleID:"com.openai.codex",title:"Codex Pet",frame:.init(x:120,y:1,width:90,height:90),layer:2,onScreen:true,windowID:2)
        XCTAssertEqual(PetAnchorSelection.select(from:[a,b])?.windowID,2)
        XCTAssertNil(PetAnchorSelection.select(from:[a, PetWindow(owner:b.owner,bundleID:b.bundleID,title:"helper 2",frame:b.frame,layer:b.layer,onScreen:true,windowID:2)]))
    }
    func testNoCodexAndRunningWithoutPet() {
        XCTAssertEqual(PetAnchorSelection.state(appRunning:false, windows:[], screens:[]).codexRunning, false)
        let state = PetAnchorSelection.state(appRunning:true, windows:[PetWindow(owner:"Codex",bundleID:"com.openai.codex",title:"",frame:.init(x:0,y:0,width:900,height:700),layer:0,onScreen:true,windowID:1)],screens:[])
        XCTAssertTrue(state.codexRunning); XCTAssertNil(state.petFrame)
    }
    func testReducerHideFallbackAndAnchorTransitions() {
        XCTAssertEqual(OverlayPresentation.reduce(.init(codexRunning:false,petFrame:nil,visibleScreenFrames:[])), .hidden)
        XCTAssertEqual(OverlayPresentation.reduce(.init(codexRunning:true,petFrame:nil,visibleScreenFrames:[])), .fallback)
        XCTAssertEqual(OverlayPresentation.reduce(.init(codexRunning:true,petFrame:.init(x:1,y:2,width:3,height:4),visibleScreenFrames:[])), .anchored)
    }
    func testAsyncEmissionsDedupeMovementAndCancellationStopsTicker() async {
        let pet=PetWindow(owner:"Codex",bundleID:"com.openai.codex",title:"Pet",frame:.init(x:10,y:10,width:90,height:90),layer:2,onScreen:true,windowID:1)
        let moved=PetWindow(owner:pet.owner,bundleID:pet.bundleID,title:pet.title,frame:.init(x:20,y:10,width:90,height:90),layer:pet.layer,onScreen:true,windowID:1)
        let source=SnapshotSource([.init(appRunning:false,windows:[],screens:[]),.init(appRunning:true,windows:[],screens:[]),.init(appRunning:true,windows:[],screens:[]),.init(appRunning:true,windows:[pet],screens:[]),.init(appRunning:true,windows:[moved],screens:[])])
        let endings=TerminationCount(); var tick:AsyncStream<Void>.Continuation!; let ticks=AsyncStream<Void>{ c in tick=c; c.onTermination={ _ in Task{await endings.increment()} } }
        let states=PetAnchorTracker(source:source,ticker:ManualTicker(stream:ticks)).states(); var iterator=states.makeAsyncIterator()
        let first=await iterator.next(); XCTAssertEqual(first?.codexRunning,false)
        tick.yield(()); let second=await iterator.next(); XCTAssertNil(second?.petFrame)
        tick.yield(()); tick.yield(()); let third=await iterator.next(); XCTAssertEqual(third?.petFrame,pet.frame)
        tick.yield(()); let fourth=await iterator.next(); XCTAssertEqual(fourth?.petFrame,moved.frame)
        tick.finish(); try? await Task.sleep(for:.milliseconds(10)); let count=await endings.value; XCTAssertEqual(count,1)
    }
    func testCancellingOuterConsumerTerminatesOpenTickerExactlyOnceAndStopsSnapshots() async {
        let source=SnapshotSource([.init(appRunning:true,windows:[],screens:[])])
        let terminated=AsyncGate(), firstState=AsyncGate(); let endings=TerminationCount()
        var tick:AsyncStream<Void>.Continuation!; let ticks=AsyncStream<Void>{ c in
            tick=c; c.onTermination={ _ in Task { await endings.increment(); await terminated.signal() } }
        }
        let states=PetAnchorTracker(source:source,ticker:ManualTicker(stream:ticks)).states()
        let consumer=Task { for await _ in states { await firstState.signal() } }
        await firstState.wait(); consumer.cancel(); await consumer.value; await terminated.wait()
        let callsBefore=await source.calls; tick.yield(()); try? await Task.sleep(for:.milliseconds(10))
        let callsAfter=await source.calls, count=await endings.value
        XCTAssertEqual(count,1); XCTAssertEqual(callsAfter,callsBefore)
    }
}
