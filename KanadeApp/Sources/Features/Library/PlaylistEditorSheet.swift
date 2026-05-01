import SwiftUI
import KanadeKit

struct PlaylistEditorSheet: View {
    enum Mode {
        case create
        case edit(Playlist)
    }

    let mode: Mode
    let onCompletion: () async -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(AppState.self) private var appState

    @State private var name: String = ""
    @State private var descriptionText: String = ""
    @State private var kind: PlaylistKind = .normal
    @State private var matchMode: MatchMode = .all
    @State private var conditions: [SmartConditionDraft] = []
    @State private var sortBy: SmartSort? = nil
    @State private var limitText: String = ""

    @State private var isSaving = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("Basics") {
                    TextField("Name", text: $name)
                    TextField("Description (optional)", text: $descriptionText, axis: .vertical)
                        .lineLimit(2...4)

                    Picker("Kind", selection: $kind) {
                        Text("Normal").tag(PlaylistKind.normal)
                        Text("Smart").tag(PlaylistKind.smart)
                    }

                    if case .edit = mode, kind == .smart {
                        Text("Smart filter cannot be changed after creation.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                if kind == .smart {
                    if case .create = mode {
                        Section("Match") {
                            Picker("Match", selection: $matchMode) {
                                Text("All conditions").tag(MatchMode.all)
                                Text("Any condition").tag(MatchMode.any)
                            }
                        }

                        Section("Conditions") {
                            ForEach($conditions) { $cond in
                                VStack(alignment: .leading, spacing: 8) {
                                    Picker("Field", selection: $cond.field) {
                                        ForEach(SmartField.allCases, id: \.self) { field in
                                            Text(label(for: field)).tag(field)
                                        }
                                    }
                                    Picker("Operator", selection: $cond.op) {
                                        ForEach(SmartOperator.allCases, id: \.self) { op in
                                            Text(label(for: op)).tag(op)
                                        }
                                    }
                                    TextField("Value", text: $cond.value)
                                }
                                .padding(.vertical, 4)
                            }
                            .onDelete { indexSet in
                                conditions.remove(atOffsets: indexSet)
                            }

                            Button {
                                conditions.append(SmartConditionDraft(field: .title, op: .contains, value: ""))
                            } label: {
                                Label("Add Condition", systemImage: "plus.circle.fill")
                            }
                        }

                        Section("Sort & Limit") {
                            Picker("Sort by", selection: $sortBy) {
                                Text("Default").tag(SmartSort?.none)
                                ForEach(SmartSort.allCases, id: \.self) { s in
                                    Text(label(for: s)).tag(SmartSort?.some(s))
                                }
                            }
                            TextField("Limit (optional)", text: $limitText)
                                #if os(iOS)
                                .keyboardType(.numberPad)
                                #endif
                        }
                    }
                }

                if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .foregroundStyle(.red)
                            .font(.footnote)
                    }
                }
            }
            .navigationTitle(modeTitle)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                    .disabled(isSaving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(role: .confirm) {
                        Task { await save() }
                    } label: {
                        if isSaving {
                            ProgressView()
                                .progressViewStyle(.circular)
                        } else {
                            Text(saveButtonTitle)
                        }
                    }
                    .disabled(!canSave || isSaving)
                }
            }
            #if os(macOS)
            .formStyle(.grouped)
            .frame(minWidth: 420, idealWidth: 480, minHeight: 340, idealHeight: 460)
            #endif
        }
        .onAppear {
            populateFromMode()
        }
        .interactiveDismissDisabled(isSaving)
    }

    private var modeTitle: String {
        switch mode {
        case .create: return "New Playlist"
        case .edit: return "Edit Playlist"
        }
    }

    private var saveButtonTitle: String {
        switch mode {
        case .create: return "Create"
        case .edit: return "Save"
        }
    }

    private var canSave: Bool {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        if case .create = mode, kind == .smart {
            if !conditions.isEmpty, !conditions.contains(where: { !$0.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
                return false
            }
        }
        return true
    }

    private func populateFromMode() {
        switch mode {
        case .create:
            break
        case .edit(let playlist):
            name = playlist.name
            descriptionText = playlist.description ?? ""
            kind = playlist.kind
        }
    }

    private func save() async {
        isSaving = true
        errorMessage = nil

        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedDescription = descriptionText.trimmingCharacters(in: .whitespacesAndNewlines)
        let descriptionValue: String? = trimmedDescription.isEmpty ? nil : trimmedDescription

        switch mode {
        case .create:
            let parsedLimit = Int(limitText.trimmingCharacters(in: .whitespacesAndNewlines))
            let smartFilter: SmartFilter? = (kind == .smart)
                ? SmartFilter(matchMode: matchMode, conditions: conditions.map { SmartCondition(field: $0.field, op: $0.op, value: $0.value) })
                : nil
            let smartSort: SmartSort? = (kind == .smart) ? sortBy : nil
            let smartLimit: Int? = (kind == .smart) ? parsedLimit : nil

            appState.client?.createPlaylist(
                name: trimmedName,
                description: descriptionValue,
                kind: kind,
                filter: smartFilter,
                limit: smartLimit,
                sortBy: smartSort
            )

        case .edit(let original):
            let descriptionUpdate: DescriptionUpdate
            if descriptionValue == original.description {
                descriptionUpdate = .unchanged
            } else if let desc = descriptionValue {
                descriptionUpdate = .set(desc)
            } else {
                descriptionUpdate = .clear
            }

            appState.client?.updatePlaylist(
                playlistId: original.id,
                name: trimmedName == original.name ? nil : trimmedName,
                description: descriptionUpdate,
                kind: kind == original.kind ? nil : kind
            )
        }

        isSaving = false
        dismiss()
        await onCompletion()
    }

    private func label(for field: SmartField) -> String {
        switch field {
        case .title: return "Title"
        case .artist: return "Artist"
        case .albumArtist: return "Album Artist"
        case .album: return "Album"
        case .composer: return "Composer"
        case .genre: return "Genre"
        }
    }

    private func label(for op: SmartOperator) -> String {
        switch op {
        case .equals: return "Equals"
        case .notEquals: return "Does Not Equal"
        case .contains: return "Contains"
        case .notContains: return "Does Not Contain"
        case .startsWith: return "Starts With"
        case .endsWith: return "Ends With"
        }
    }

    private func label(for sort: SmartSort) -> String {
        switch sort {
        case .title: return "Title"
        case .artist: return "Artist"
        case .album: return "Album"
        case .genre: return "Genre"
        }
    }
}

private struct SmartConditionDraft: Identifiable, Equatable {
    let id = UUID()
    var field: SmartField
    var op: SmartOperator
    var value: String
}
