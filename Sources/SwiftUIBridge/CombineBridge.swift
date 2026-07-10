import Foundation
import SwiftInterpreter

/// Combine's spine, inline: the interpreter is synchronous, so scheduler
/// hops (`subscribe(on:)`/`receive(on:)`) collapse to the calling slice —
/// the inline-await doctrine applied to publishers. A publisher IS its
/// already-computed outcome; `sink` delivers immediately.
final class PublisherBox {
    enum Outcome {
        case success(RuntimeValue)
        case failure(RuntimeValue)
        /// `decode(type: T.self, …)` with an UNBOUND generic: the bytes wait
        /// for a downstream type witness (`replaceError(with: Instance)` —
        /// native infers T backward through it).
        case pendingDecode(Data, JSONDecoderBox)
    }

    var outcome: Outcome

    init(_ outcome: Outcome) {
        self.outcome = outcome
    }
}

/// `Result(catching:)` value — `.publisher` lifts it into the spine.
final class ResultBox {
    let outcome: PublisherBox.Outcome

    init(_ outcome: PublisherBox.Outcome) {
        self.outcome = outcome
    }
}

func combineHostObjectConstructor(_ name: String) -> HostFunction? {
    guard name == "Result" else { return nil }
    return HostFunction(name: name) { args, ctx in
        guard let closure = args.closure(labeled: "catching") ?? args.firstUnlabeledClosure else {
            // `Result.success(x)` spellings arrive as implicit members, not here.
            return .native(ChainedImplicitCall(
                base: .implicitMember("Result"), member: "init", arguments: args))
        }
        do {
            return .native(ResultBox(.success(try ctx.callClosure(closure, arguments: []))))
        } catch let interpreted as InterpretedThrow {
            return .native(ResultBox(.failure(interpreted.value)))
        } catch let error as RuntimeError where !error.fatal {
            return .native(ResultBox(.failure(.native(error.message))))
        }
    }
}

@MainActor
func combineBridgeMember(_ name: String, on value: Any) -> RuntimeValue? {
    if let result = value as? ResultBox {
        switch name {
        case "publisher":
            return .native(PublisherBox(result.outcome))
        case "get":
            return .hostFunction(HostFunction(name: "get") { _, _ in
                switch result.outcome {
                case .success(let value): return value
                case .failure(let error): throw InterpretedThrow(value: error)
                case .pendingDecode: return .nilValue
                }
            })
        default:
            return nil
        }
    }
    if let session = value as? URLSessionBox, name == "dataTaskPublisher" {
        _ = session
        return .hostFunction(HostFunction(name: name) { args, _ in
            guard let url = NetworkBridge.url(from: args.labeled("for") ?? args.positional(0)) else {
                return .native(PublisherBox(.failure(.native("dataTaskPublisher: no URL"))))
            }
            do {
                let (data, response) = try NetworkBridge.respond(to: url)
                return .native(PublisherBox(.success(.native(TupleValue(
                    labels: ["data", "response"],
                    values: [.native(data), .native(HTTPResponseBox(response))])))))
            } catch {
                return .native(PublisherBox(.failure(.native("\(error)"))))
            }
        })
    }
    guard let publisher = value as? PublisherBox else { return nil }
    switch name {
    case "eraseToAnyPublisher", "subscribe", "receive":
        // Scheduler hops and erasure are identity in the inline model.
        return .hostFunction(HostFunction(name: name) { _, _ in .native(publisher) })
    case "decode":
        return .hostFunction(HostFunction(name: "decode") { args, ctx in
            guard case .success(let payload) = publisher.outcome else {
                return .native(publisher)
            }
            guard case .host(let any) = payload, let data = any as? Data,
                  case .host(let decoderAny)? = args.labeled("decoder"),
                  let decoder = decoderAny as? JSONDecoderBox,
                  let interpreter = ctx as? Interpreter else {
                return .native(PublisherBox(.failure(.native("decode: unsupported upstream"))))
            }
            let typeValue = args.labeled("type") ?? args.positional(0)
            if case .hostFunction? = typeValue {
                // Unbound generic — wait for the replaceError witness.
                return .native(PublisherBox(.pendingDecode(data, decoder)))
            }
            do {
                guard let json = try? JSONSerialization.jsonObject(with: data),
                      let typeValue else {
                    return .native(PublisherBox(.failure(.native("decode: not JSON"))))
                }
                let decoded = try JSONDecodeBridge.decode(
                    typeValue, json: json, interpreter: interpreter, decoder: decoder)
                return .native(PublisherBox(.success(decoded)))
            } catch {
                return .native(PublisherBox(.failure(.native("\(error)"))))
            }
        })
    case "mapError":
        return .hostFunction(HostFunction(name: "mapError") { args, ctx in
            guard case .failure(let error) = publisher.outcome,
                  let closure = args.firstUnlabeledClosure else {
                return .native(publisher)
            }
            return .native(PublisherBox(.failure(try ctx.callClosure(closure, arguments: [error]))))
        })
    case "replaceError":
        return .hostFunction(HostFunction(name: "replaceError") { args, ctx in
            let fallback = args.labeled("with") ?? args.positional(0) ?? .nilValue
            switch publisher.outcome {
            case .success:
                return .native(publisher)
            case .failure:
                return .native(PublisherBox(.success(fallback)))
            case .pendingDecode(let data, let decoder):
                // The fallback IS the generic's type witness (native infers
                // T backward through replaceError) — decode as its type.
                guard case .instance(let witness) = fallback,
                      let interpreter = ctx as? Interpreter,
                      let json = try? JSONSerialization.jsonObject(with: data),
                      let decoded = try? JSONDecodeBridge.decode(
                          .type(witness.symbol), json: json,
                          interpreter: interpreter, decoder: decoder) else {
                    return .native(PublisherBox(.success(fallback)))
                }
                return .native(PublisherBox(.success(decoded)))
            }
        })
    case "tryMap":
        return .hostFunction(HostFunction(name: "tryMap") { args, ctx in
            guard case .success(let payload) = publisher.outcome,
                  let closure = args.firstUnlabeledClosure else {
                return .native(publisher)
            }
            do {
                return .native(PublisherBox(.success(try ctx.callClosure(closure, arguments: [payload]))))
            } catch let interpreted as InterpretedThrow {
                return .native(PublisherBox(.failure(interpreted.value)))
            } catch let error as RuntimeError where !error.fatal {
                return .native(PublisherBox(.failure(.native(error.message))))
            }
        })
    case "map":
        return .hostFunction(HostFunction(name: "map") { args, ctx in
            guard case .success(let payload) = publisher.outcome else {
                return .native(publisher)
            }
            if let closure = args.firstUnlabeledClosure {
                return .native(PublisherBox(.success(try ctx.callClosure(closure, arguments: [payload]))))
            }
            if case .host(let any)? = args.positional(0), let keyPath = any as? KeyPathStub,
               let component = keyPath.components.first {
                // `.map(\.data)` — tuple/label keypath reads.
                if let tuple = payload.tupleValue, let read = tuple.value(for: component) {
                    return .native(PublisherBox(.success(read)))
                }
            }
            return .native(publisher)
        })
    case "sink":
        return .hostFunction(HostFunction(name: "sink") { args, ctx in
            let receiveValue = args.closure(labeled: "receiveValue") ?? args.lastUnlabeledClosure
            let receiveCompletion = args.closure(labeled: "receiveCompletion")
            switch publisher.outcome {
            case .success(let payload):
                if let receiveValue {
                    _ = try ctx.callClosure(receiveValue, arguments: [payload])
                }
                if let receiveCompletion {
                    _ = try? ctx.callClosure(
                        receiveCompletion, arguments: [.implicitMember("finished")])
                }
            case .failure(let error):
                if let receiveCompletion {
                    _ = try? ctx.callClosure(receiveCompletion, arguments: [.native(
                        ImplicitMemberCall(
                            name: "failure",
                            arguments: CallArguments(arguments: [.init(label: nil, value: error)])))])
                }
            case .pendingDecode:
                break // no witness ever arrived — nothing to deliver
            }
            return .native(AnyCancellableStub())
        })
    default:
        return nil
    }
}

/// `.store(in: &cancellables)` sinks accept it; `.cancel()` is inert.
final class AnyCancellableStub {}
