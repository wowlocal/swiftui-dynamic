# Claude project instructions

Read and follow `AGENTS.md` before changing this repository. Its
Swiftinterface-first bridge rule is binding: ordinary SwiftUI/SDK API gaps are
fixed through BridgeGen, shared coercions, or reusable generated adapters,
never through per-API special cases. Only the narrowly defined,
interface-inexpressible SwiftUI magic in `AGENTS.md` may remain handwritten.
