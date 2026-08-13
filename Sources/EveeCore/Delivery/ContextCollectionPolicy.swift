public struct ContextCollectionPolicy: Equatable, Sendable {
    public var collectsDeliveryIdentity: Bool
    public var collectsSelectedText: Bool
    public var collectsWindowMetadata: Bool
    public var collectsWebAndFileMetadata: Bool
    public var collectsRecipientMetadata: Bool
    public var collectsVisibleText: Bool

    public init(
        collectsDeliveryIdentity: Bool,
        collectsSelectedText: Bool,
        collectsWindowMetadata: Bool,
        collectsWebAndFileMetadata: Bool,
        collectsRecipientMetadata: Bool,
        collectsVisibleText: Bool
    ) {
        self.collectsDeliveryIdentity = collectsDeliveryIdentity
        self.collectsSelectedText = collectsSelectedText
        self.collectsWindowMetadata = collectsWindowMetadata
        self.collectsWebAndFileMetadata = collectsWebAndFileMetadata
        self.collectsRecipientMetadata = collectsRecipientMetadata
        self.collectsVisibleText = collectsVisibleText
    }

    public static func ordinaryDictation(
        retainMetadata: Bool,
        captureVisibleText: Bool
    ) -> Self {
        Self(
            collectsDeliveryIdentity: true,
            collectsSelectedText: false,
            collectsWindowMetadata: retainMetadata,
            collectsWebAndFileMetadata: retainMetadata,
            collectsRecipientMetadata: retainMetadata,
            collectsVisibleText: captureVisibleText
        )
    }

    public static func selectionTransformation(
        retainMetadata: Bool,
        captureVisibleText: Bool = false
    ) -> Self {
        Self(
            collectsDeliveryIdentity: true,
            collectsSelectedText: true,
            collectsWindowMetadata: retainMetadata,
            collectsWebAndFileMetadata: retainMetadata,
            collectsRecipientMetadata: retainMetadata,
            collectsVisibleText: captureVisibleText
        )
    }
}
