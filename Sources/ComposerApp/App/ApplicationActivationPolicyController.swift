import AppKit

/// Applies BonsAI's persisted Dock preference without coupling Settings or tests to `NSApp`.
/// AppDelegate owns the live instance; tests inject recorders instead of mutating the test runner's
/// own activation policy and Dock presence.
@MainActor
final class ApplicationActivationPolicyController {
  typealias PolicySetter = (NSApplication.ActivationPolicy) -> Bool
  typealias Activator = () -> Void

  private let setPolicy: PolicySetter
  private let activate: Activator

  init(setPolicy: @escaping PolicySetter, activate: @escaping Activator) {
    self.setPolicy = setPolicy
    self.activate = activate
  }

  static func policy(hidesDockIcon: Bool) -> NSApplication.ActivationPolicy {
    hidesDockIcon ? .accessory : .regular
  }

  /// `restoreFocus` is true at launch and while a visible workspace changes policy. Changing from a
  /// regular app to an accessory can disturb activation, so immediately reacquire it without asking
  /// the window controller to rebuild or reposition either workspace panel.
  @discardableResult
  func apply(hidesDockIcon: Bool, restoreFocus: Bool) -> Bool {
    let applied = setPolicy(Self.policy(hidesDockIcon: hidesDockIcon))
    guard applied else { return false }
    if restoreFocus { activate() }
    return true
  }
}
