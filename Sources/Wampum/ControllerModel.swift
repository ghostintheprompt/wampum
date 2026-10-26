import SwiftUI
import WorkbenchCore

@MainActor final class ControllerModel:ObservableObject {
    @Published var enabled=false
    @Published var handoff=""
    @Published var prepared=false
    @Published var status="Controller is off. Qwen remains local."
    @Published var owner="No controller connected"
    @Published var observationText=""
    @Published var observationTicket:UUID?
    @Published var checkpointText=""
    @Published var checkpointTicket:UUID?
    @Published var remaining=""
    private var preparedScenario=""
    private var lease:ControllerLease?
    private var observations:[String:JSONValue]=[:]
    private var submissions:[String:String]=[:]
    private var actionTickets:Set<UUID>=[]
    private var deniedObservation:String?
    private var deniedCheckpoint:String?
    let mailbox:ControllerMailbox
    init(directory:URL){mailbox=ControllerMailbox(stateDirectory:directory);try? mailbox.revoke()}
    static func scenario(_ model:WorkbenchModel)->String{model.session.lab?.id ?? "general:"+model.session.project}
    func prepare(model:WorkbenchModel){
        guard !enabled else{return}
        do {
            guard !model.privacyBlocked else{throw WorkbenchError.invalid("Repair privacy settings first.")}
            let text="SCENARIO HANDOFF / operator-maintained, not fresh observations\n"+(model.session.lab?.context ?? "General workspace")+"\nSCOPE:\n"+model.session.scope+"\nCHECKPOINT:\n"+model.session.notes
            let masker=try ContentMasker(rules:model.privacy.aliasRules,detectSecrets:model.privacy.detectSecrets)
            handoff=model.privacy.maskModelRequests ? masker.mask(text).text:text
            guard handoff.utf8.count<=16000 else{throw WorkbenchError.invalid("Handoff exceeds 16 KB. Condense it before sharing.")}
            preparedScenario=Self.scenario(model);prepared=true;status="Review and edit this exact handoff before enabling the controller."
        }catch{status=error.localizedDescription}
    }
    func enable(model:WorkbenchModel){
        guard !enabled else{return}
        do {
            guard prepared,preparedScenario==Self.scenario(model),!handoff.isEmpty,handoff.utf8.count<=16000 else{throw WorkbenchError.invalid("Prepare and review a handoff for the current scenario first.")}
            guard !model.persistenceBlocked,!model.privacyBlocked else{throw WorkbenchError.invalid("Repair local state/privacy storage before enabling.")}
            let token=UUID().uuidString+UUID().uuidString
            try mailbox.grant(token:token)
            lease=ControllerLease(token:token,scenario:preparedScenario,context:handoff)
            observations=[:];submissions=[:];actionTickets=[];deniedObservation=nil;deniedCheckpoint=nil;observationTicket=nil;checkpointTicket=nil;owner="Waiting for one controller";enabled=true;status="Enabled for 15 minutes, 20 proposals, 120 calls and 256 KB of returned data. Browser actions still require review."
            updateBudget()
        }catch{status=error.localizedDescription}
    }
    func revoke(model:WorkbenchModel,stopBrowser:Bool=true){
        if let id=model.browser.proposedControllerID {model.browser.actionOutcomes[id]="revoked";model.browser.proposedControllerID=nil;model.browser.proposed=nil}
        lease=nil;enabled=false;prepared=false;owner="No controller connected";observations=[:];observationTicket=nil;observationText="";checkpointTicket=nil;checkpointText="";submissions=[:];actionTickets=[]
        do{try mailbox.revoke();status="Controller revoked. No more context or actions are available."}catch{status="Controller revoked in memory; remove stale access file after repairing storage: "+error.localizedDescription}
        if stopBrowser {model.browser.disconnect()}
    }
    private func updateBudget(){if let lease{remaining="\(max(0,lease.maxActions-lease.actions)) proposals / \(max(0,lease.maxCalls-lease.calls)) calls / \(max(0,lease.maxBytes-lease.sharedBytes)/1024) KB remain until "+lease.expiresAt.formatted(date:.omitted,time:.shortened)}}
    func poll(model:WorkbenchModel){
        if let lease,(Date()>=lease.expiresAt || lease.scenario != Self.scenario(model)){revoke(model:model);status="Controller revoked after expiry or scenario change."}
        do {
            for request in try mailbox.requests() {
                let value:JSONValue
                do {
                    guard var active=lease,enabled else{throw WorkbenchError.invalid("Controller is disabled. Enable it from Wampum after reviewing the handoff.")}
                    try active.authorize(request,scenario:Self.scenario(model));lease=active;owner=String(request.clientName.prefix(80))+" (client-reported name)"
                    let result=try handle(request,model:model)
                    if var active=lease {try active.account(result);lease=active}
                    value=result
                }catch{value = .object(["error":.string(error.localizedDescription)])}
                try mailbox.respond(request,value:value)
            }
            updateBudget()
        }catch{status="Controller queue needs repair: "+error.localizedDescription}
    }
    private func boundedText(_ value:JSONValue?,limit:Int=8000)throws->String {
        guard let text=value?.string,!text.isEmpty,text.utf8.count<=limit else{throw WorkbenchError.invalid("Missing text or value exceeds the review limit.")};return text
    }
    private func previewReply(_ value:JSONValue)throws {if var active=lease{try active.account(value)}}
    private func handle(_ request:ControllerRequest,model:WorkbenchModel)throws->JSONValue {
        switch request.tool {
        case "wampum_status":
            let actions=Dictionary(uniqueKeysWithValues:actionTickets.map{($0.uuidString,JSONValue.string(model.browser.actionOutcomes[$0] ?? "awaiting operator review"))})
            return .object(["enabled":.bool(enabled),"browserConnected":.bool(model.browser.connected),"browserBusy":.bool(model.browser.busy || model.browser.capturing),"actions":.object(actions),"submissions":.object(submissions.mapValues{.string($0)}),"observationPending":observationTicket.map{.string($0.uuidString)} ?? .null,"remaining":.string(remaining)])
        case "wampum_context":return .object(["context":.string(lease?.context ?? ""),"provenance":.string("Operator-reviewed frozen handoff. No editor/history or other scenarios included automatically.")])
        case "wampum_propose_browser_action":
            guard model.browser.connected,!model.browser.busy,!model.browser.capturing,model.browser.proposed==nil else{throw WorkbenchError.invalid("Browser disconnected, busy, or an action is already pending. Do not repeat this request.")}
            let name=try boundedText(request.arguments["tool"],limit:100)
            let reason=try boundedText(request.arguments["reason"],limit:2000)
            guard case .object?=request.arguments["arguments"] else{throw WorkbenchError.invalid("Tool arguments must be an object.")}
            let call=BrowserCall(name:name,arguments:request.arguments["arguments"]!)
            try previewReply(.object(["ticket":.string(request.id.uuidString),"status":.string("awaiting operator review; not executed")]))
            if !["browser_navigate","browser_snapshot","browser_console_messages","browser_network_requests"].contains(call.name),!model.browser.snapshotFresh{throw WorkbenchError.invalid("Current page observation is stale. Refresh it in Wampum before proposing another interaction.")}
            try model.browser.validate(call);try lease?.reserveAction()
            model.browser.proposed=call;model.browser.proposedControllerID=request.id
            model.browser.explanation="External controller proposal (unexecuted): "+reason
            model.browser.status="Controller action pending. Review exact arguments in Browser before allowing."
            actionTickets.insert(request.id)
            return .object(["ticket":.string(request.id.uuidString),"status":.string("awaiting operator review; not executed")])
        case "wampum_request_observation":
            guard observationTicket==nil else{throw WorkbenchError.invalid("An observation is already awaiting review. Do not submit another.")}
            guard model.browser.connected,!model.browser.busy,!model.browser.capturing,model.browser.snapshotFresh else{throw WorkbenchError.invalid("Browser observation is unavailable, busy or stale. Refresh it in Wampum first.")}
            try previewReply(.object(["ticket":.string(request.id.uuidString),"status":.string("awaiting operator review; no page content shared")]))
            let masker=try ContentMasker(rules:model.privacy.aliasRules,detectSecrets:model.privacy.detectSecrets)
            let text=model.browser.snapshot
            guard text.utf8.count<=24000 else{throw WorkbenchError.invalid("Page snapshot exceeds 24 KB. Review a smaller observation manually first.")}
            let reviewed=model.privacy.maskModelRequests ? masker.mask(text).text:text
            guard deniedObservation != reviewed else{throw WorkbenchError.invalid("This unchanged observation was denied. Do not request it again without changed conditions.")}
            observationText=reviewed
            observationTicket=request.id;observations[request.id.uuidString] = .object(["status":.string("awaiting operator review")])
            return .object(["ticket":.string(request.id.uuidString),"status":.string("awaiting operator review; no page content shared")])
        case "wampum_read_observation":
            let ticket=try boundedText(request.arguments["ticket"],limit:80)
            guard let value=observations[ticket] else{throw WorkbenchError.invalid("Unknown observation ticket for this controller connection.")};return value
        case "wampum_submit_checkpoint":
            guard checkpointTicket==nil else{throw WorkbenchError.invalid("A checkpoint submission is already pending review.")}
            try previewReply(.object(["ticket":.string(request.id.uuidString),"status":.string("awaiting operator review; not saved to case notes")]))
            let text=try boundedText(request.arguments["text"]);guard text != deniedCheckpoint else{throw WorkbenchError.invalid("This unchanged checkpoint was denied.")};checkpointText=text;try lease?.reserveAction();checkpointTicket=request.id;submissions[request.id.uuidString]="awaiting operator review"
            return .object(["ticket":.string(request.id.uuidString),"status":.string("awaiting operator review; not saved to case notes")])
        case "wampum_stop":revoke(model:model);return .object(["status":.string("controller revoked; browser shutdown requested")])
        default:throw WorkbenchError.invalid("Tool unavailable.")
        }
    }
    func shareObservation(){
        guard enabled,let ticket=observationTicket,observationText.utf8.count<=24000 else{return}
        observations[ticket.uuidString] = .object(["status":.string("approved"),"snapshot":.string(observationText),"provenance":.string("Operator-reviewed page snapshot; text may have been edited or masked.")]);observationTicket=nil;observationText="";status="Only the reviewed observation is available to the controller."
    }
    func denyObservation(){deniedObservation=observationText;if let ticket=observationTicket{observations[ticket.uuidString] = .object(["status":.string("denied; no page content shared")])};observationTicket=nil;observationText=""}
    func saveCheckpoint(model:WorkbenchModel){
        guard enabled,let ticket=checkpointTicket,!checkpointText.isEmpty,checkpointText.utf8.count<=8000 else{return}
        model.snapshot();model.session.notes += "\n\nCONTROLLER SUBMISSION / operator accepted, not independently verified:\n"+checkpointText;model.persist();submissions[ticket.uuidString]="operator accepted into case notes; not an independently verified result";checkpointTicket=nil;checkpointText=""
    }
    func denyCheckpoint(){deniedCheckpoint=checkpointText;if let ticket=checkpointTicket{submissions[ticket.uuidString]="operator denied"};checkpointTicket=nil;checkpointText=""}
}
