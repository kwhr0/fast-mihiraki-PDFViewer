#import "MyDocument.h"

@interface AppDelegate : NSObject<NSApplicationDelegate>
@end

@implementation AppDelegate

- (void)applicationWillBecomeActive:(NSNotification *)aNotification {
	NSArray *docs = [[NSDocumentController sharedDocumentController] documents];
	for (int i = 0; i < docs.count; i++) {
		id doc = docs[i];
		if ([doc isKindOfClass:MyDocument.class]) [(MyDocument *)doc refreshPDF];
	}
}

@end
