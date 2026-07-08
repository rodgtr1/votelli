import VotelliCore

// The free app is pure bootstrap: no extensions registered, so EngineRegistry
// holds only the built-in base.en engine and the Pro extension points stay empty.
// A Pro build performs its registration here before calling VotelliMain().
VotelliMain()
