import SwiftUI
import UniformTypeIdentifiers

struct SkillsSettingsView: View {
  @StateObject private var vm = SkillsLibraryViewModel()
  @State private var searchFocused = false

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      headerRow
      contentRow
    }
    .onDrop(of: [UTType.fileURL, UTType.url, UTType.plainText], isTargeted: nil) { providers in
      vm.handleDrop(providers)
    }
    .sheet(isPresented: $vm.showInstallSheet) {
      SkillsInstallSheet(vm: vm)
        .frame(minWidth: 520, minHeight: 340)
    }
    .task { await vm.load() }
  }

  private var headerRow: some View {
    HStack(spacing: 8) {
      Spacer(minLength: 0)
      ToolbarSearchField(
        placeholder: "Search skills",
        text: $vm.searchText,
        onFocusChange: { focused in searchFocused = focused },
        onSubmit: {}
      )
      .frame(width: 240)

      Button {
        vm.prepareInstall(mode: vm.installMode)
      } label: {
        Label("Add", systemImage: "plus")
      }
    }
  }

  private var contentRow: some View {
    HStack(alignment: .top, spacing: 12) {
      skillsList
        .frame(minWidth: 260, maxWidth: 320)
      detailPanel
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  private var skillsList: some View {
    Group {
      if vm.isLoading {
        VStack(spacing: 8) {
          ProgressView()
          Text("Loading skills…")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else if vm.filteredSkills.isEmpty {
        VStack(spacing: 10) {
          Image(systemName: "sparkles")
            .font(.system(size: 32))
            .foregroundStyle(.secondary)
          Text("No Skills")
            .font(.title3)
            .fontWeight(.medium)
          Text("Install skills from folder, zip, or URL to get started.")
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else {
        List(selection: $vm.selectedSkillId) {
          ForEach(vm.filteredSkills) { skill in
            HStack(alignment: .center, spacing: 8) {
              Toggle(
                "",
                isOn: Binding(
                  get: { skill.isSelected },
                  set: { value in
                    vm.updateSkillSelection(id: skill.id, value: value)
                  }
                )
              )
              .labelsHidden()
              .controlSize(.small)

              VStack(alignment: .leading, spacing: 4) {
                Text(skill.displayName)
                  .font(.body.weight(.medium))
                Text(skill.summary)
                  .font(.caption)
                  .foregroundStyle(.secondary)
                  .lineLimit(2)
                if !skill.tags.isEmpty {
                  Text(skill.tags.joined(separator: " · "))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                }
              }
              Spacer(minLength: 8)
              HStack(spacing: 6) {
                MCPServerTargetToggle(
                  provider: .codex,
                  isOn: Binding(
                    get: { skill.targets.codex },
                    set: { value in
                      vm.updateSkillTarget(id: skill.id, target: .codex, value: value)
                    }
                  ),
                  disabled: false
                )
                MCPServerTargetToggle(
                  provider: .claude,
                  isOn: Binding(
                    get: { skill.targets.claude },
                    set: { value in
                      vm.updateSkillTarget(id: skill.id, target: .claude, value: value)
                    }
                  ),
                  disabled: false
                )
              }
            }
            .padding(.vertical, 4)
            .tag(skill.id as String?)
          }
        }
        .listStyle(.inset)
      }
    }
    .background(
      RoundedRectangle(cornerRadius: 8, style: .continuous)
        .fill(Color(nsColor: .textBackgroundColor))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.15)))
    )
  }

  private var detailPanel: some View {
    VStack(alignment: .leading, spacing: 12) {
      if let skill = vm.selectedSkill {
        VStack(alignment: .leading, spacing: 6) {
          Text(skill.displayName)
            .font(.title3.weight(.semibold))
          Text(skill.summary)
            .font(.subheadline)
            .foregroundStyle(.secondary)
        }
        Divider()
        VStack(alignment: .leading, spacing: 8) {
          Text("Targets")
            .font(.headline)
          HStack(spacing: 8) {
            Label("Codex", systemImage: "sparkles")
              .font(.caption)
              .foregroundStyle(.secondary)
            Label("Claude", systemImage: "chevron.left.slash.chevron.right")
              .font(.caption)
              .foregroundStyle(.secondary)
          }
          if let path = skill.path {
            Text(path)
              .font(.caption)
              .foregroundStyle(.secondary)
          }
        }
        Divider()
        VStack(alignment: .leading, spacing: 8) {
          Text("SKILL.md")
            .font(.headline)
          ScrollView {
            Text("Preview will appear here once loaded.")
              .font(.caption)
              .foregroundStyle(.secondary)
              .frame(maxWidth: .infinity, alignment: .leading)
              .padding(.vertical, 4)
          }
          .frame(maxHeight: 220)
          .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
              .fill(Color(nsColor: .textBackgroundColor))
              .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.15)))
          )
        }
        Spacer(minLength: 0)
        HStack(spacing: 8) {
          Button("Reveal in Finder") {}
          Button("Reinstall") {}
          Button("Uninstall", role: .destructive) {}
          Spacer()
        }
        .disabled(true)
      } else {
        VStack(spacing: 12) {
          Image(systemName: "doc.text")
            .font(.system(size: 32))
            .foregroundStyle(.secondary)
          Text("Select a skill to view details")
            .font(.subheadline)
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      }
    }
    .padding(12)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .background(
      RoundedRectangle(cornerRadius: 8, style: .continuous)
        .fill(Color(nsColor: .textBackgroundColor))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.15)))
    )
  }
}

private struct SkillsInstallSheet: View {
  @ObservedObject var vm: SkillsLibraryViewModel
  @State private var importerPresented = false
  @State private var isDropTargeted = false
  private let rowWidth: CGFloat = 420
  private let fieldWidth: CGFloat = 320

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text("Install Skill")
        .font(.title3)
        .fontWeight(.semibold)

      dropArea

      HStack {
        Spacer(minLength: 0)
        Picker("", selection: $vm.installMode) {
          ForEach(SkillInstallMode.allCases, id: \.self) { mode in
            Text(mode.title).tag(mode)
          }
        }
        .labelsHidden()
        .pickerStyle(.segmented)
        .frame(width: 240)
        Spacer(minLength: 0)
      }

      Group {
        switch vm.installMode {
        case .folder:
          sourceRow(value: vm.pendingInstallURL?.path ?? "Choose a folder…") {
            importerPresented = true
          }
        case .zip:
          sourceRow(value: vm.pendingInstallURL?.path ?? "Choose a zip file…") {
            importerPresented = true
          }
        case .url:
          HStack {
            Spacer(minLength: 0)
            TextField("https://example.com/skill.zip", text: $vm.pendingInstallText)
              .textFieldStyle(.roundedBorder)
              .frame(width: rowWidth)
            Spacer(minLength: 0)
          }
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)

      Spacer(minLength: 0)

      VStack(alignment: .leading, spacing: 6) {
        Text(" ")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      .frame(height: 32)

      HStack {
        Button("Test") {}
          .buttonStyle(.bordered)
        Spacer()
        Button("Cancel") { vm.cancelInstall() }
        Button("Install") { vm.finishInstall() }
          .buttonStyle(.borderedProminent)
          .disabled(!canInstall)
      }
    }
    .padding(16)
    .onDrop(of: [UTType.fileURL, UTType.url, UTType.plainText], isTargeted: $isDropTargeted) {
      providers in
      handleDrop(providers)
    }
    .fileImporter(
      isPresented: $importerPresented,
      allowedContentTypes: allowedTypes,
      allowsMultipleSelection: false
    ) { result in
      if case .success(let urls) = result {
        vm.pendingInstallURL = urls.first
      }
    }
  }

  private var dropArea: some View {
    ZStack {
      RoundedRectangle(cornerRadius: 10, style: .continuous)
        .strokeBorder(
          isDropTargeted ? Color.accentColor : Color.secondary.opacity(0.3),
          style: StrokeStyle(lineWidth: 1, dash: [6, 4])
        )
        .frame(height: 120)
        .background(
          RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(isDropTargeted ? Color.accentColor.opacity(0.08) : Color.clear)
        )
      VStack(spacing: 6) {
        Image(systemName: "tray.and.arrow.down")
          .font(.system(size: 28))
          .foregroundStyle(isDropTargeted ? Color.accentColor : Color.secondary)
        Text("Drop a skill folder, zip file, or URL")
          .font(.subheadline)
          .foregroundStyle(.secondary)
        if let url = vm.pendingInstallURL {
          Text(url.path)
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.middle)
        } else if !vm.pendingInstallText.isEmpty {
          Text(vm.pendingInstallText)
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.middle)
        }
      }
      .padding(.horizontal, 16)
    }
  }

  private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
    for provider in providers {
      if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
        provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
          guard let data = item as? Data,
            let url = URL(dataRepresentation: data, relativeTo: nil)
          else { return }
          Task { @MainActor in
            applyFileURL(url)
          }
        }
        return true
      }
      if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
        provider.loadItem(forTypeIdentifier: UTType.url.identifier, options: nil) { item, _ in
          if let url = item as? URL {
            Task { @MainActor in
              vm.installMode = .url
              vm.pendingInstallText = url.absoluteString
            }
          }
        }
        return true
      }
      if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
        provider.loadItem(forTypeIdentifier: UTType.plainText.identifier, options: nil) { item, _ in
          let text: String?
          if let data = item as? Data {
            text = String(data: data, encoding: .utf8)
          } else {
            text = item as? String
          }
          guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines),
            !text.isEmpty
          else { return }
          Task { @MainActor in
            vm.installMode = .url
            vm.pendingInstallText = text
          }
        }
        return true
      }
    }
    return false
  }

  private func applyFileURL(_ url: URL) {
    let isZip = url.pathExtension.lowercased() == "zip"
    let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
    if isDirectory {
      vm.installMode = .folder
      vm.pendingInstallURL = url
    } else if isZip {
      vm.installMode = .zip
      vm.pendingInstallURL = url
    } else {
      vm.installMode = .zip
      vm.pendingInstallURL = url
    }
  }

  private var canInstall: Bool {
    switch vm.installMode {
    case .folder, .zip:
      return vm.pendingInstallURL != nil
    case .url:
      return !vm.pendingInstallText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
  }

  private var allowedTypes: [UTType] {
    switch vm.installMode {
    case .folder:
      return [.folder]
    case .zip:
      return [.zip]
    case .url:
      return [.data]
    }
  }

  private func sourceRow(value: String, action: @escaping () -> Void) -> some View {
    HStack(spacing: 8) {
      Spacer(minLength: 0)
      HStack(spacing: 8) {
        TextField("", text: .constant(value))
          .textFieldStyle(.roundedBorder)
          .disabled(true)
          .frame(width: fieldWidth)
        Button("Choose…") { action() }
      }
      .frame(width: rowWidth, alignment: .center)
      Spacer(minLength: 0)
    }
  }
}
