#import <Foundation/Foundation.h>

#if __has_attribute(swift_private)
#define AC_SWIFT_PRIVATE __attribute__((swift_private))
#else
#define AC_SWIFT_PRIVATE
#endif

/// The "github-mark-white" asset catalog image resource.
static NSString * const ACImageNameGithubMarkWhite AC_SWIFT_PRIVATE = @"github-mark-white";

#undef AC_SWIFT_PRIVATE