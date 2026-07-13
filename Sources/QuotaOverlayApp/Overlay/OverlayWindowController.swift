import AppKit
import SwiftUI

enum OverlayPlacement {
    static func visibleScreen(for pet: CGRect, screens: [CGRect]) -> CGRect? {
        let center = CGPoint(x:pet.midX,y:pet.midY)
        return screens.first { $0.contains(center) } ?? screens.max { $0.intersection(pet).width * $0.intersection(pet).height < $1.intersection(pet).width * $1.intersection(pet).height }
    }
    static func frame(pet: CGRect, panel: CGSize, screens: [CGRect], gap: CGFloat, offset: CGPoint = .zero) -> CGRect {
        guard let screen=visibleScreen(for:pet,screens:screens) else {
            return CGRect(origin:.init(x:pet.origin.x+offset.x,y:pet.origin.y+offset.y),size:panel)
        }
        var x=pet.maxX+gap; if x+panel.width > screen.maxX { x=pet.minX-gap-panel.width }
        let defaultFrame=clamp(CGRect(x:x,y:pet.midY-panel.height/2,width:panel.width,height:panel.height),to:screen)
        return clamp(defaultFrame.offsetBy(dx:offset.x,dy:offset.y),to:screen)
    }
    static func fallbackFrame(savedOrigin:CGPoint,panel:CGSize,screens:[CGRect])->CGRect {
        let proposed=CGRect(origin:savedOrigin,size:panel); guard !screens.isEmpty else{return proposed}
        let intersections=screens.map{($0,$0.intersection(proposed).width * $0.intersection(proposed).height)}
        let bestIntersection=intersections.max{$0.1 < $1.1}
        let screen: CGRect
        if let bestIntersection,bestIntersection.1 > 0 { screen=bestIntersection.0 }
        else { screen=screens.min { distance(savedOrigin,$0) < distance(savedOrigin,$1) }! }
        return clamp(proposed,to:screen)
    }
    private static func clamp(_ frame:CGRect,to screen:CGRect)->CGRect {
        let maxX=max(screen.minX,screen.maxX-frame.width),maxY=max(screen.minY,screen.maxY-frame.height)
        return .init(x:min(max(frame.minX,screen.minX),maxX),y:min(max(frame.minY,screen.minY),maxY),width:frame.width,height:frame.height)
    }
    private static func distance(_ point:CGPoint,_ rect:CGRect)->CGFloat { let x=min(max(point.x,rect.minX),rect.maxX),y=min(max(point.y,rect.minY),rect.maxY); return hypot(point.x-x,point.y-y) }
}

enum FallbackGripEvent:Equatable { case down(CGPoint),moved(CGPoint),up(CGPoint) }
enum FallbackGripAction:Equatable { case none,beginDrag,endDrag }
struct FallbackGripInteraction {
    let threshold:CGFloat; private var start:CGPoint?; private var dragging=false
    init(threshold:CGFloat=4){self.threshold=threshold}
    mutating func handle(_ event:FallbackGripEvent)->FallbackGripAction { switch event {
    case .down(let p):start=p;dragging=false;return .none
    case .moved(let p):guard let start,!dragging,hypot(p.x-start.x,p.y-start.y)>=threshold else{return .none};dragging=true;return .beginDrag
    case .up:defer{start=nil;dragging=false};return dragging ? .endDrag : .none }
    }
}

enum PanelInteractionEvent:Equatable {
    case mouseDown(point:CGPoint,clickCount:Int)
    case mouseMoved(CGPoint)
    case mouseUp
    case singleClickDelayElapsed
}
enum PanelInteractionAction:Equatable {
    case dragBegan,dragEnded,scheduleSingleClick,cancelSingleClick,singleClick,resetRequested
}
struct PanelInteractionReducer {
    let threshold:CGFloat
    private var start:CGPoint?
    private var dragging=false
    private var singleClickPending=false
    init(threshold:CGFloat=4){self.threshold=threshold}
    mutating func handle(_ event:PanelInteractionEvent)->[PanelInteractionAction] {
        switch event {
        case .mouseDown(let point,let clickCount):
            if clickCount >= 2 {
                start=nil;dragging=false
                let cancellation:[PanelInteractionAction]=singleClickPending ? [.cancelSingleClick] : []
                singleClickPending=false
                return cancellation + [.resetRequested]
            }
            start=point;dragging=false;return []
        case .mouseMoved(let point):
            guard let start,!dragging,hypot(point.x-start.x,point.y-start.y)>=threshold else{return []}
            dragging=true;return [.dragBegan]
        case .mouseUp:
            defer{start=nil;dragging=false}
            if dragging{return [.dragEnded]}
            guard start != nil else{return []}
            singleClickPending=true;return [.scheduleSingleClick]
        case .singleClickDelayElapsed:
            guard singleClickPending else{return []}
            singleClickPending=false;return [.singleClick]
        }
    }
}

enum OverlayPresentation: Equatable { case hidden, fallback, anchored
    static func reduce(_ state: PetAnchorState) -> Self { !state.codexRunning ? .hidden : (state.petFrame == nil ? .fallback : .anchored) }
}

final class NonActivatingPanel: NSPanel { override var canBecomeKey: Bool { false }; override var canBecomeMain: Bool { false } }

@MainActor protocol OverlayPanel: AnyObject {
    var frame: CGRect { get }
    func setFrame(_ frame: CGRect); func show(); func hide()
    func installInteractionHandlers(
        dragBegan: @escaping @MainActor () -> Void,
        dragEnded: @escaping @MainActor () -> Void,
        resetRequested: @escaping @MainActor () -> Void
    )
    func removeInteractionHandlers()
    func setFallbackMode(_ enabled:Bool)
}
@MainActor protocol OverlayPositionPersistence: AnyObject {
    func load() -> CGPoint?
    func save(_ point: CGPoint)
    func loadRelativeOffset() -> CGPoint?
    func saveRelativeOffset(_ point: CGPoint)
    func clearRelativeOffset()
}

@MainActor final class DefaultsOverlayPosition: OverlayPositionPersistence {
    private let defaults: UserDefaults
    private let key = "QuotaOverlayFallbackOrigin"
    private let relativeOffsetKey = "QuotaOverlayPetRelativeOffset"
    init(_ defaults: UserDefaults) { self.defaults = defaults }
    func load() -> CGPoint? { guard let d=defaults.dictionary(forKey:key),let x=d["x"] as? Double,let y=d["y"] as? Double else{return nil}; return .init(x:x,y:y) }
    func save(_ point:CGPoint) { defaults.set(["x":point.x,"y":point.y],forKey:key) }
    func loadRelativeOffset() -> CGPoint? { guard let d=defaults.dictionary(forKey:relativeOffsetKey),let x=d["x"] as? Double,let y=d["y"] as? Double else{return nil}; return .init(x:x,y:y) }
    func saveRelativeOffset(_ point:CGPoint) { defaults.set(["x":point.x,"y":point.y],forKey:relativeOffsetKey) }
    func clearRelativeOffset() { defaults.removeObject(forKey:relativeOffsetKey) }
}

@MainActor final class AppKitOverlayPanel: OverlayPanel {
    let panel: NSPanel
    private let manualRefresh: @MainActor () -> Void
    private var interactionView: PanelInteractionView?
    init(store:QuotaStore) {
        manualRefresh = { Task { await store.refresh() } }
        panel=NonActivatingPanel(contentRect:.init(x:0,y:0,width:190,height:62),styleMask:[.borderless,.nonactivatingPanel],backing:.buffered,defer:false)
        panel.isOpaque=false; panel.backgroundColor = .clear; panel.hasShadow=false; panel.level = .floating; panel.collectionBehavior=[.canJoinAllSpaces,.fullScreenAuxiliary]; panel.hidesOnDeactivate=false; panel.isMovableByWindowBackground=true
        panel.contentView=NSHostingView(rootView:QuotaPanelView(store:store).padding(4))
    }
    var frame:CGRect { panel.frame }; func setFrame(_ frame:CGRect){panel.setFrame(frame,display:true)}; func show(){panel.orderFrontRegardless()}; func hide(){panel.orderOut(nil)}
    func installInteractionHandlers(dragBegan:@escaping @MainActor()->Void,dragEnded:@escaping @MainActor()->Void,resetRequested:@escaping @MainActor()->Void) {
        guard interactionView == nil, let contentView=panel.contentView else{return}
        let view=PanelInteractionView(frame:contentView.bounds)
        view.autoresizingMask=[.width,.height]
        view.panel=panel
        view.dragBegan=dragBegan
        view.dragEnded=dragEnded
        view.resetRequested=resetRequested
        view.clicked=manualRefresh
        view.toolTip="拖动调整位置，双击恢复默认"
        view.setAccessibilityElement(false)
        contentView.addSubview(view,positioned:.above,relativeTo:nil)
        interactionView=view
    }
    func removeInteractionHandlers(){interactionView?.removeFromSuperview();interactionView=nil}
    func setFallbackMode(_ enabled:Bool){}
}

@MainActor final class PanelInteractionView:NSView {
    weak var panel:NSPanel?
    var dragBegan:(@MainActor()->Void)?
    var dragEnded:(@MainActor()->Void)?
    var resetRequested:(@MainActor()->Void)?
    var clicked:(@MainActor()->Void)?
    private var reducer=PanelInteractionReducer()
    private var deferredClick:DispatchWorkItem?
    override func acceptsFirstMouse(for event:NSEvent?)->Bool { true }
    override func mouseDown(with event:NSEvent) {
        perform(reducer.handle(.mouseDown(point:event.locationInWindow,clickCount:event.clickCount)))
        guard event.clickCount < 2 else{return}
        while let next=window?.nextEvent(matching:[.leftMouseDragged,.leftMouseUp]) {
            if next.type == .leftMouseDragged {
                let actions=reducer.handle(.mouseMoved(next.locationInWindow))
                perform(actions)
                if actions.contains(.dragBegan) {
                    panel?.performDrag(with:event)
                    perform(reducer.handle(.mouseUp))
                    return
                }
            } else if next.type == .leftMouseUp {
                perform(reducer.handle(.mouseUp))
                return
            }
        }
    }
    private func perform(_ actions:[PanelInteractionAction]) {
        for action in actions {
            switch action {
            case .dragBegan:dragBegan?()
            case .dragEnded:dragEnded?()
            case .singleClick:clicked?()
            case .resetRequested:resetRequested?()
            case .cancelSingleClick:deferredClick?.cancel();deferredClick=nil
            case .scheduleSingleClick:
                deferredClick?.cancel()
                let work=DispatchWorkItem { [weak self] in Task { @MainActor in
                    guard let self else{return}
                    self.deferredClick=nil
                    self.perform(self.reducer.handle(.singleClickDelayElapsed))
                } }
                deferredClick=work
                DispatchQueue.main.asyncAfter(deadline:.now()+NSEvent.doubleClickInterval,execute:work)
            }
        }
    }
}

@MainActor final class OverlayWindowController {
    private let panel: any OverlayPanel; private let tracker: any PetAnchorTracking; private let persistence:any OverlayPositionPersistence; private var task: Task<Void,Never>?; private var isFallback = false
    private var relativeOffset:CGPoint
    private var currentState:PetAnchorState?
    private var isUserDragging=false
    private var isStarted=false
    init(store: QuotaStore, tracker: any PetAnchorTracking = PetAnchorTracker(), defaults: UserDefaults = .standard) {
        let persistence=DefaultsOverlayPosition(defaults)
        self.panel=AppKitOverlayPanel(store:store); self.tracker=tracker; self.persistence=persistence; self.relativeOffset=persistence.loadRelativeOffset() ?? .zero
    }
    init(panel:any OverlayPanel,tracker:any PetAnchorTracking,persistence:any OverlayPositionPersistence){self.panel=panel;self.tracker=tracker;self.persistence=persistence;self.relativeOffset=persistence.loadRelativeOffset() ?? .zero}
    func start() {
        guard task == nil else{return}
        isStarted=true
        panel.installInteractionHandlers(
            dragBegan:{ [weak self] in self?.userDragBegan() },
            dragEnded:{ [weak self] in self?.userDragEnded() },
            resetRequested:{ [weak self] in self?.userResetRequested() }
        )
        task=Task { @MainActor [weak self,tracker] in for await state in tracker.states() { guard let self,!Task.isCancelled else{return}; self.apply(state) } }
    }
    func stop() { isStarted=false;isUserDragging=false;task?.cancel();task=nil;currentState=nil;panel.hide();panel.removeInteractionHandlers() }
    func resetRelativeOffset() { relativeOffset = .zero; persistence.clearRelativeOffset(); if isStarted,let currentState { apply(currentState) } }
    private func apply(_ state:PetAnchorState) {
        currentState=state
        guard !isUserDragging else{return}
        switch OverlayPresentation.reduce(state) { case .hidden: isFallback=false;panel.setFallbackMode(false);panel.hide(); case .anchored: isFallback=false;panel.setFallbackMode(false);if let pet=state.petFrame { panel.setFrame(OverlayPlacement.frame(pet:pet,panel:panel.frame.size,screens:state.visibleScreenFrames,gap:8,offset:relativeOffset)); panel.show() }; case .fallback: isFallback=true;panel.setFallbackMode(true);showFallback(screens:state.visibleScreenFrames) }
    }
    private func showFallback(screens:[CGRect]) { let screen=screens.first ?? NSScreen.main?.visibleFrame ?? .zero; let origin=persistence.load() ?? .init(x:max(screen.minX,screen.maxX-panel.frame.width-16),y:screen.minY+16); panel.setFrame(OverlayPlacement.fallbackFrame(savedOrigin:origin,panel:panel.frame.size,screens:screens.isEmpty ? [screen] : screens)); panel.show() }
    private func userDragBegan(){guard isStarted else{return};isUserDragging=true}
    private func userResetRequested(){guard isStarted else{return};resetRelativeOffset()}
    private func userDragEnded(){
        guard isStarted,isUserDragging else{return}
        isUserDragging=false
        guard let state=currentState else {
            if isFallback { persistence.save(panel.frame.origin) }
            return
        }
        if OverlayPresentation.reduce(state) == .anchored,let pet=state.petFrame {
            let defaultFrame=OverlayPlacement.frame(pet:pet,panel:panel.frame.size,screens:state.visibleScreenFrames,gap:8)
            relativeOffset = .init(x:panel.frame.minX-defaultFrame.minX,y:panel.frame.minY-defaultFrame.minY)
            persistence.saveRelativeOffset(relativeOffset)
        } else if OverlayPresentation.reduce(state) == .fallback {
            persistence.save(panel.frame.origin)
        }
        apply(state)
    }
}
