@class MyDocument;

@interface MyView : NSView

@property(nonatomic, weak) MyDocument *doc;

- (void)setupPrefetch;
- (void)prefetch:(int)page dir:(bool)dir;
- (void)refresh;
- (void)requestCursor;
- (void)close;

@end
