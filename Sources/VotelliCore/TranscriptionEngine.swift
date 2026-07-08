import Foundation

/// A speech-to-text backend. The free build ships one conformer (the whisper
/// base.en `Transcriber`); a Pro build registers additional engines at startup.
public protocol TranscriptionEngine: AnyObject {
    /// Transcribe 16kHz mono samples in [-1,1]. Returns nil on failure or empty input.
    func transcribe(_ samples: [Float]) -> String?
}

/// Describes an engine the app can load: how to identify it, show it in a picker,
/// tell whether it's ready (e.g. its model is downloaded), and instantiate it.
///
/// Loading is deferred to `makeEngine` because it's expensive (loads a model off
/// the main thread) and shouldn't happen just to list the engine in Preferences.
public struct EngineDescriptor {
    /// Stable identifier persisted in `Settings.selectedEngineID`.
    public let id: String
    /// Shown in the engine picker.
    public let displayName: String
    /// Whether the engine can be loaded right now (model present, etc.).
    public let isAvailable: () -> Bool
    /// Instantiate and load the engine. Called off the main thread; nil on failure.
    public let makeEngine: () -> TranscriptionEngine?

    public init(
        id: String,
        displayName: String,
        isAvailable: @escaping () -> Bool,
        makeEngine: @escaping () -> TranscriptionEngine?
    ) {
        self.id = id
        self.displayName = displayName
        self.isAvailable = isAvailable
        self.makeEngine = makeEngine
    }
}

/// The set of engines the app knows about. The free build registers only the
/// built-in base.en engine (see `AppDelegate.registerBuiltInEngines`); a Pro build
/// registers more at startup before `VotelliMain()`.
///
/// Main-thread only.
public final class EngineRegistry {
    public static let shared = EngineRegistry()
    private init() {}

    private var descriptors: [EngineDescriptor] = []

    /// Register an engine. Re-registering the same `id` replaces the prior entry,
    /// so a Pro build can override a built-in if it ever needs to.
    public func register(_ descriptor: EngineDescriptor) {
        if let index = descriptors.firstIndex(where: { $0.id == descriptor.id }) {
            descriptors[index] = descriptor
        } else {
            descriptors.append(descriptor)
        }
    }

    /// All registered engines, in registration order.
    public var all: [EngineDescriptor] { descriptors }

    public func descriptor(id: String) -> EngineDescriptor? {
        descriptors.first { $0.id == id }
    }

    /// The first registered engine that reports itself available, if any.
    public var firstAvailable: EngineDescriptor? {
        descriptors.first { $0.isAvailable() }
    }
}
