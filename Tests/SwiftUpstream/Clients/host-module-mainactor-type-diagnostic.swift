import TypeIsolationHost

extension ImportedStruct {
  public func isolatedMember() {}
}

nonisolated func useImportedStruct(_ value: ImportedStruct) {
  value.isolatedMember()
}
