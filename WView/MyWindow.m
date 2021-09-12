@interface MyWindow : NSWindow
@end

@implementation MyWindow

- (BOOL)canBecomeKeyWindow { return TRUE; }

- (instancetype)initWithContentRect:(NSRect)contentRect styleMask:(NSUInteger)styleMask backing:(NSBackingStoreType)backingType defer:(BOOL)flag {
	self = [super initWithContentRect:contentRect styleMask:NSBorderlessWindowMask backing:backingType defer:flag];
	[self setLevel:NSPopUpMenuWindowLevel];
	[self setFrame:NSScreen.mainScreen.frame display:FALSE];
	return self;
}

@end
