func invalidSyntheticAsyncPropertyRead() async throws -> Int {
    try "swift".syntheticAsyncCount
}
