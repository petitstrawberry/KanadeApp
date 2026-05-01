import SwiftUI
import KanadeKit

func trackListAllSelected(selectedIds: Set<String>, trackIds: [String]) -> Bool {
    !trackIds.isEmpty && selectedIds.count == trackIds.count
}

func toggleTrackListSelection(selectedIds: inout Set<String>, trackIds: [String]) {
    if trackListAllSelected(selectedIds: selectedIds, trackIds: trackIds) {
        selectedIds.removeAll()
    } else {
        selectedIds = Set(trackIds)
    }
}

func selectedTracks(from tracks: [Track], selectedIds: Set<String>) -> [Track] {
    tracks.filter { selectedIds.contains($0.id) }
}

struct TrackListEditToolbar: ToolbarContent {
    let isEditing: Bool
    let allSelected: Bool
    let hasSelection: Bool
    private let _editModeBinding: Any?
    let onToggleEditMac: () -> Void
    let onToggleSelectAll: () -> Void
    let onAddToQueue: () -> Void
    let onAddToPlaylist: () -> Void
    let onRemove: (() -> Void)?

    #if os(iOS)
    init(isEditing: Bool, allSelected: Bool, hasSelection: Bool,
         editMode: Binding<EditMode>,
         onToggleEditMac: @escaping () -> Void,
         onToggleSelectAll: @escaping () -> Void,
         onAddToQueue: @escaping () -> Void,
         onAddToPlaylist: @escaping () -> Void,
         onRemove: (() -> Void)? = nil) {
        self.isEditing = isEditing
        self.allSelected = allSelected
        self.hasSelection = hasSelection
        self._editModeBinding = editMode
        self.onToggleEditMac = onToggleEditMac
        self.onToggleSelectAll = onToggleSelectAll
        self.onAddToQueue = onAddToQueue
        self.onAddToPlaylist = onAddToPlaylist
        self.onRemove = onRemove
    }
    #else
    init(isEditing: Bool, allSelected: Bool, hasSelection: Bool,
         onToggleEditMac: @escaping () -> Void,
         onToggleSelectAll: @escaping () -> Void,
         onAddToQueue: @escaping () -> Void,
         onAddToPlaylist: @escaping () -> Void,
         onRemove: (() -> Void)? = nil) {
        self.isEditing = isEditing
        self.allSelected = allSelected
        self.hasSelection = hasSelection
        self._editModeBinding = nil
        self.onToggleEditMac = onToggleEditMac
        self.onToggleSelectAll = onToggleSelectAll
        self.onAddToQueue = onAddToQueue
        self.onAddToPlaylist = onAddToPlaylist
        self.onRemove = onRemove
    }
    #endif

    @ToolbarContentBuilder
    var body: some ToolbarContent {
        #if os(iOS)
        ToolbarItem(placement: .primaryAction) {
            EditButton()
                .environment(\.editMode, (_editModeBinding as! Binding<EditMode>))
        }

        if isEditing {
            ToolbarItem(placement: .topBarLeading) {
                Button(allSelected ? "Deselect All" : "Select All") {
                    onToggleSelectAll()
                }
            }

            ToolbarItemGroup(placement: .bottomBar) {
                Button {
                    onAddToQueue()
                } label: {
                    Label("Add to Queue", systemImage: "plus.circle")
                }
                .disabled(!hasSelection)

                Button {
                    onAddToPlaylist()
                } label: {
                    Label("Add to Playlist", systemImage: "text.badge.plus")
                }
                .disabled(!hasSelection)

                if let onRemove {
                    Button(role: .destructive) {
                        onRemove()
                    } label: {
                        Label("Remove", systemImage: "minus.circle")
                    }
                    .disabled(!hasSelection)
                }

                Spacer()
            }
        }
        #else
        ToolbarItem(placement: .primaryAction) {
            Button(isEditing ? "Done" : "Edit") {
                onToggleEditMac()
            }
        }

        if isEditing {
            ToolbarItem(placement: .primaryAction) {
                Button(allSelected ? "Deselect All" : "Select All") {
                    onToggleSelectAll()
                }
            }

            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button {
                        onAddToQueue()
                    } label: {
                        Label("Add to Queue", systemImage: "plus.circle")
                    }

                    Button {
                        onAddToPlaylist()
                    } label: {
                        Label("Add to Playlist", systemImage: "text.badge.plus")
                    }

                    if let onRemove {
                        Divider()

                        Button(role: .destructive) {
                            onRemove()
                        } label: {
                            Label("Remove", systemImage: "minus.circle")
                        }
                    }
                } label: {
                    Label("Actions", systemImage: "ellipsis.circle")
                }
                .disabled(!hasSelection)
            }
        }
        #endif
    }
}

extension View {
    func trackListRowStyle(top: CGFloat = 0, leading: CGFloat = 16, bottom: CGFloat = 0, trailing: CGFloat = 16) -> some View {
        listRowInsets(EdgeInsets(top: top, leading: leading, bottom: bottom, trailing: trailing))
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
    }
}
