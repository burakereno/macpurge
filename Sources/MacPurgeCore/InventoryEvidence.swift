import Foundation

package struct ApplicationIdentity: Codable, Hashable, Sendable {
  package let name: String
  package let bundleID: String
  package let path: String
  package init(name: String, bundleID: String, path: String) {
    self.name = name; self.bundleID = bundleID; self.path = path
  }
}

/// Read-only discovery evidence. It describes data; it never grants cleanup permission.
package struct InventoryEvidence: Codable, Hashable, Sendable {
  package enum Kind: String, Codable, Sendable {
    case cache, build, workspace, extensionFiles, logs, history, settings, checkpoint, update
    case application, applicationData, toolVersion, installer, modelFragment, other
  }
  package enum Finding: String, Codable, Sendable {
    case recognized, projectPresent, missingProject, unknownProject, remoteProject
    case registeredExtension, unregisteredExtension, unknownRegistry
    case installedApplication, unmatchedApplication
    case currentVersion, olderVersion, unknownVersion, installerMatch, duplicateDownload
    case orphanModel, partialModel, unknownModelReferences
  }
  package struct PrivateAllocation: Codable, Hashable, Sendable {
    package let allocated: Int64
    package let privateBytes: Int64
    package init(allocated: Int64, privateBytes: Int64) {
      self.allocated = allocated
      self.privateBytes = privateBytes
    }
  }

  package let owner: String
  package let kind: Kind
  package let finding: Finding
  package let rule: String
  package var projectPath: String? = nil
  package var inspectionOnly = true
  package var privateAllocation: PrivateAllocation? = nil
  package var note: String? = nil
  package var management: String? = nil

  package init(owner: String, kind: Kind, finding: Finding = .recognized, rule: String,
               projectPath: String? = nil, inspectionOnly: Bool = true) {
    self.owner = owner
    self.kind = kind
    self.finding = finding
    self.rule = rule
    self.projectPath = projectPath
    self.inspectionOnly = inspectionOnly
  }
}
