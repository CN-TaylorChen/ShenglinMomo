#import <UIKit/UIKit.h>

@interface SLTrimController : UIViewController

- (instancetype)initWithPack:(NSDictionary *)pack;
@property (nonatomic, copy) void (^onSaved)(void);

@end
