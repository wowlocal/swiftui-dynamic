import Darwin

func darwinSocketMemoryLayouts() -> String {
    [
        MemoryLayout<sockaddr>.size,
        MemoryLayout<sockaddr>.stride,
        MemoryLayout<sockaddr>.alignment,
        MemoryLayout<sockaddr_in>.size,
        MemoryLayout<sockaddr_in>.stride,
        MemoryLayout<sockaddr_in>.alignment,
        MemoryLayout<sockaddr_in6>.size,
        MemoryLayout<sockaddr_in6>.stride,
        MemoryLayout<sockaddr_in6>.alignment,
        MemoryLayout<sockaddr_storage>.size,
        MemoryLayout<sockaddr_storage>.stride,
        MemoryLayout<sockaddr_storage>.alignment,
        MemoryLayout<sockaddr_un>.size,
        MemoryLayout<sockaddr_un>.stride,
        MemoryLayout<sockaddr_un>.alignment,
    ].map(String.init).joined(separator: ",")
}
