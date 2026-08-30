#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Registers Charker's Draco decompressor with GLTFKit2. Calling this more than
/// once is harmless; the class name is stored globally by GLTFKit2.
FOUNDATION_EXPORT void CharkerRegisterDracoDecompressor(void);

NS_ASSUME_NONNULL_END
