import EveeCore
import Foundation

private func checkContextPolicy() {
    let ordinary = ContextCollectionPolicy.ordinaryDictation(
        retainMetadata: false,
        captureVisibleText: false
    )
    precondition(ordinary.collectsDeliveryIdentity)
    precondition(!ordinary.collectsSelectedText)
    precondition(!ordinary.collectsWindowMetadata)
    precondition(!ordinary.collectsVisibleText)

    let transform = ContextCollectionPolicy.selectionTransformation(retainMetadata: false)
    precondition(transform.collectsSelectedText)

    print("context-policy: passed")
}

let arguments = CommandLine.arguments.dropFirst()
if arguments == ["--filter", "context-policy"] {
    checkContextPolicy()
} else {
    fputs("usage: evee-core-checks --filter context-policy\n", stderr)
    exit(EXIT_FAILURE)
}
