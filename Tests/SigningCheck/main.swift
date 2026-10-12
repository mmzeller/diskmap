import Foundation

// Checks, on a real Mac, that DiskMap's signing works the way the updater and macOS's
// privacy settings rely on. Usage: signing-check <signed.app> <resigned.app> <adhoc.app>
let arguments = CommandLine.arguments
guard arguments.count == 4 else {
    print("usage: signing-check <signed.app> <resigned.app> <adhoc.app>")
    exit(2)
}
let signed = URL(fileURLWithPath: arguments[1])
let resigned = URL(fileURLWithPath: arguments[2])
let adhoc = URL(fileURLWithPath: arguments[3])
var failures = 0

func check(_ condition: Bool, _ what: String) {
    if condition {
        print("::notice::PASS \(what)")
    } else {
        print("::error::FAIL \(what)")
        failures += 1
    }
}

guard let requirement = CodeSigning.requirement(of: signed) else {
    print("::error::FAIL the signed build has no designated requirement")
    exit(1)
}
print("::notice::Designated requirement: \(CodeSigning.describe(requirement))")
check(CodeSigning.hasStableIdentity(signed), "a key-signed build has a stable identity")
check(!CodeSigning.hasStableIdentity(adhoc), "an ad hoc build does not")
check(CodeSigning.satisfies(signed, requirement), "the signed build meets its own requirement")
check(CodeSigning.satisfies(resigned, requirement), "a different build signed with the same key meets the first build's requirement (macOS keeps Full Disk Access)")
check(!CodeSigning.satisfies(adhoc, requirement), "an ad hoc build does not meet it (the updater refuses it)")
if let adhocRequirement = CodeSigning.requirement(of: adhoc) {
    check(!CodeSigning.satisfies(resigned, adhocRequirement), "ad hoc requirements are tied to one exact build")
}
exit(failures == 0 ? 0 : 1)
