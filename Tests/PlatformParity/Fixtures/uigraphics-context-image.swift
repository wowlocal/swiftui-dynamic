import UIKit

func uiGraphicsContextImageLifecycle() -> String {
    let before = UIGraphicsGetImageFromCurrentImageContext() == nil
        ? "nil" : "image"
    UIGraphicsBeginImageContextWithOptions(
        CGSize(width: 2, height: 2), false, 1)
    let outer = UIGraphicsGetImageFromCurrentImageContext() == nil
        ? "nil" : "image"
    UIGraphicsBeginImageContextWithOptions(
        CGSize(width: 1, height: 1), false, 1)
    let inner = UIGraphicsGetImageFromCurrentImageContext() == nil
        ? "nil" : "image"
    UIGraphicsEndImageContext()
    let restored = UIGraphicsGetImageFromCurrentImageContext() == nil
        ? "nil" : "image"
    UIGraphicsEndImageContext()
    let after = UIGraphicsGetImageFromCurrentImageContext() == nil
        ? "nil" : "image"
    return [before, outer, inner, restored, after].joined(separator: ",")
}
