import SwiftUI

/// Searchable browser for the public AutoEq results library.
struct AutoEQLibrarySheet: View {
    @ObservedObject var library: AutoEQLibraryService
    var onApply: (AutoEQProfile) -> Void
    var onImportFile: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var applyError: String?

    var body: some View {
        VStack(spacing: 0) {
            header
            searchBar
            Divider().overlay(OmniTheme.strokeSoft)

            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            footer
        }
        .frame(width: 420, height: 520)
        .background(OmniTheme.bgDeep.opacity(0.92))
        .task {
            await library.ensureIndexLoaded()
        }
        .alert("AutoEQ", isPresented: Binding(
            get: { applyError != nil || library.lastError != nil },
            set: { if !$0 { applyError = nil; library.clearError() } }
        )) {
            Button("OK", role: .cancel) {
                applyError = nil
                library.clearError()
            }
        } message: {
            Text(applyError ?? library.lastError ?? "")
        }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("AutoEQ Library")
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                    .foregroundStyle(OmniTheme.textPrimary)
                Text("Profiles from jaakkopasanen/AutoEq")
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .foregroundStyle(OmniTheme.textSecondary)
            }
            Spacer()
            Button {
                Task { await library.refreshIndex(force: true) }
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(OmniTheme.accent)
            }
            .buttonStyle(.plain)
            .disabled(library.isLoadingIndex)
            .help("Refresh library index")

            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(OmniTheme.textSecondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(OmniTheme.textSecondary)
            TextField("Search headphones…", text: $library.searchQuery)
                .textFieldStyle(.plain)
                .font(.system(size: 13, weight: .medium, design: .rounded))
            if !library.searchQuery.isEmpty {
                Button {
                    library.searchQuery = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(OmniTheme.textSecondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(OmniTheme.fill, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .padding(.horizontal, 16)
        .padding(.bottom, 10)
    }

    @ViewBuilder
    private var content: some View {
        if library.isLoadingIndex && library.entries.isEmpty {
            ProgressView("Loading library…")
                .controlSize(.small)
                .tint(OmniTheme.accent)
        } else if library.filteredEntries.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "headphones")
                    .font(.system(size: 28, weight: .medium))
                    .foregroundStyle(OmniTheme.accent.opacity(0.7))
                Text(library.searchQuery.isEmpty ? "Loading entries…" : "No matches")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(OmniTheme.textSecondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List(library.filteredEntries.prefix(400)) { entry in
                Button {
                    Task { await apply(entry) }
                } label: {
                    HStack(spacing: 10) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(entry.name)
                                .font(.system(size: 12, weight: .semibold, design: .rounded))
                                .foregroundStyle(OmniTheme.textPrimary)
                                .lineLimit(2)
                            Text("\(entry.source) · \(entry.formFactor)")
                                .font(.system(size: 10, weight: .medium, design: .rounded))
                                .foregroundStyle(OmniTheme.textSecondary)
                        }
                        Spacer(minLength: 4)
                        if library.isLoadingProfile {
                            ProgressView().controlSize(.mini)
                        } else {
                            Image(systemName: "plus.circle.fill")
                                .foregroundStyle(OmniTheme.accent)
                        }
                    }
                    .padding(.vertical, 2)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .listRowBackground(Color.clear)
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
        }
    }

    private var footer: some View {
        HStack {
            Button {
                onImportFile()
                dismiss()
            } label: {
                Label("Import file…", systemImage: "doc.badge.plus")
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
            }
            .buttonStyle(.plain)
            .foregroundStyle(OmniTheme.accent)

            Spacer()

            Text("\(library.filteredEntries.count) shown")
                .font(.system(size: 10, weight: .medium, design: .rounded))
                .foregroundStyle(OmniTheme.textSecondary.opacity(0.7))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(OmniTheme.bgMid.opacity(0.6))
    }

    private func apply(_ entry: AutoEQLibraryService.Entry) async {
        do {
            let profile = try await library.downloadProfile(entry)
            onApply(profile)
            dismiss()
        } catch {
            applyError = error.localizedDescription
        }
    }
}
