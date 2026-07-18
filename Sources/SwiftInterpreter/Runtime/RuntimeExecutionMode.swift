/// Invalid physical-worker configuration is reported as a value so opting in
/// to parallel execution cannot trap the embedding process.
public nonisolated enum RuntimeParallelismConfigurationError:
    Error, Sendable, Equatable
{
    case invalidMaximumParallelism(Int)
}

/// Validated process-local capacity for opt-in physical source work.
public nonisolated struct RuntimeParallelismConfiguration:
    Sendable, Equatable
{
    public let maximumParallelism: Int

    public init(maximumParallelism: Int) throws {
        guard maximumParallelism > 0 else {
            throw RuntimeParallelismConfigurationError
                .invalidMaximumParallelism(maximumParallelism)
        }
        self.maximumParallelism = maximumParallelism
    }
}

/// Interpreter scheduling policy. Cooperative execution remains the default;
/// parallel mode is explicit and admits only source work that can first be
/// lowered through the checked snapshot boundary.
public nonisolated enum RuntimeExecutionMode: Sendable, Equatable {
    case cooperative
    case parallel(RuntimeParallelismConfiguration)
}
