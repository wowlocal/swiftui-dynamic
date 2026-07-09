#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Runs the block, catching any Objective-C exception — the automatic
/// bridging tier turns caught exceptions into interpreter errors instead
/// of process aborts.
NSException *_Nullable DSUICatchObjCException(void (NS_NOESCAPE ^block)(void));

NS_ASSUME_NONNULL_END
