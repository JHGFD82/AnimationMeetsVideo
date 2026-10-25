import SwiftUI

/// Removing media or deleting timelines that the project's timelines use,
/// waiting for the person to agree: the question asked says how many uses
/// go with them, and Find All lists them instead. See docs/browser.md,
/// "Removing".
struct RemovalRequest: Identifiable {
    let id = UUID()
    var title: String
    var message: String
    /// The button that goes ahead: "Remove" or "Delete".
    var action: String
    /// What Find All shows.
    var queries: [UsesFinder.Query]
    var perform: () -> Void

    /// The question for removing `names` (assets or timelines, `noun`
    /// "clip" or "timeline"), with `uses` the uses that would go with them.
    init(
        removing names: [String], noun: String, action: String, uses: [ItemUse], in project: EditingProject,
        queries: [UsesFinder.Query], perform: @escaping () -> Void
    ) {
        let one = names.count == 1
        let what = one ? "“\(names[0])”" : "\(names.count) \(noun)s"
        title = action == "Remove" ? "Remove \(what) from the project?" : "Delete \(what)?"
        message = Self.message(subject: one ? "It" : "They", object: one ? "it" : "them", uses: uses, in: project, action: action)
        self.action = action
        self.queries = queries
        self.perform = perform
    }

    /// "It is used 3 times, in Main and Scene 2. Removing it also deletes
    /// those 2 clips and takes it off 1 effect. You can undo this."
    static func message(subject: String, object: String, uses: [ItemUse], in project: EditingProject, action: String) -> String {
        let times = uses.count == 1 ? "once" : "\(uses.count) times"
        var timelineIDs: [UUID] = []
        for use in uses where !timelineIDs.contains(use.timelineID) { timelineIDs.append(use.timelineID) }
        let names = timelineIDs.compactMap { project.timeline(id: $0)?.name }
        let place = names.count <= 3 ? "in \(Self.listed(names))" : "in \(names.count) timelines"
        let clips = uses.filter { !$0.isEffectInput }.count, inputs = uses.count - clips
        var consequences: [String] = []
        if clips > 0 { consequences.append("deletes \(clips == 1 ? "that clip" : "those \(clips) clips")") }
        if inputs > 0 { consequences.append("takes \(object) off \(inputs == 1 ? "the effect" : "the \(inputs) effects") using \(object) as an input") }
        let verb = subject == "It" ? "is" : "are"
        return "\(subject) \(verb) used \(times), \(place). \(action == "Remove" ? "Removing" : "Deleting") \(object) also "
            + "\(consequences.joined(separator: " and ")). You can undo this."
    }

    /// "Main", "Main and Intro", "Main, Intro and Outro".
    private static func listed(_ names: [String]) -> String {
        guard names.count > 1 else { return names.first ?? "" }
        return names.dropLast().joined(separator: ", ") + " and " + names[names.count - 1]
    }
}

extension View {
    /// Asks `request`'s question while it is set: go ahead, Find All (which
    /// opens the Find All panel and removes nothing), or cancel.
    func removalConfirmation(_ request: Binding<RemovalRequest?>, finder: UsesFinder?) -> some View {
        alert(
            request.wrappedValue?.title ?? "",
            isPresented: Binding(get: { request.wrappedValue != nil }, set: { if !$0 { request.wrappedValue = nil } }),
            presenting: request.wrappedValue
        ) { pending in
            Button(pending.action, role: .destructive) { pending.perform() }
            if let finder {
                Button("Find All") { finder.show(pending.queries) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { pending in
            Text(pending.message)
        }
    }
}
