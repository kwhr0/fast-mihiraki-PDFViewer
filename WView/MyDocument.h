@class MyView;

@interface MyDocument : NSDocument {
	IBOutlet MyView *_view;
}

@property(nonatomic) NSURL *url;
@property(nonatomic) float aspect;
@property(nonatomic) int page;
@property(nonatomic) BOOL cover, direction;
#ifdef MUPDF
@property(nonatomic) fz_context *ctx;
@property(nonatomic) fz_document *pdf;
#else
@property(nonatomic) CGPDFDocumentRef pdf;
#endif

- (NSSize)pageSize:(int)page;
- (IBAction)switchCover:(id)sender;
- (IBAction)switchDirection:(id)sender;
- (void)refreshPDF;
- (int)pageCount;

@end
