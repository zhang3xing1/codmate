import Foundation

enum ExtensionsSettingsTab: String, CaseIterable, Identifiable {
  case mcp
  case skills

  var id: String { rawValue }
}
