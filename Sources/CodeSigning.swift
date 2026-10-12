import Foundation
import Security

/// Reads who signed a copy of DiskMap, so an update is only installed when it was signed
/// with the same key as the copy that's running.
enum CodeSigning {
    /// The rule macOS uses to recognize this app (its "designated requirement"), or nil if unsigned.
    static func requirement(of url: URL) -> SecRequirement? {
        guard let code = staticCode(url) else { return nil }
        var requirement: SecRequirement?
        guard SecCodeCopyDesignatedRequirement(code, SecCSFlags(), &requirement) == errSecSuccess else { return nil }
        return requirement
    }

    static func describe(_ requirement: SecRequirement) -> String {
        var text: CFString?
        guard SecRequirementCopyString(requirement, SecCSFlags(), &text) == errSecSuccess, let value = text else { return "" }
        return value as String
    }

    /// True when the app is signed with a key. Ad hoc copies are recognized only by their exact
    /// contents (a "cdhash"), which changes with every build.
    static func hasStableIdentity(_ url: URL) -> Bool {
        guard let requirement = requirement(of: url) else { return false }
        let text = describe(requirement)
        return !text.isEmpty && !text.contains("cdhash")
    }

    /// True when the app at `url` is validly signed and meets `requirement`.
    static func satisfies(_ url: URL, _ requirement: SecRequirement) -> Bool {
        guard let code = staticCode(url) else { return false }
        return SecStaticCodeCheckValidity(code, SecCSFlags(), requirement) == errSecSuccess
    }

    private static func staticCode(_ url: URL) -> SecStaticCode? {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, SecCSFlags(), &code) == errSecSuccess else { return nil }
        return code
    }
}
