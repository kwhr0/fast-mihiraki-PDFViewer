#import "MyDocument.h"
#import "MyView.h"

#define SETTINGS        @"settings"
#define FILEURL			@"url"
#define NO_COVER		@"noCover"
#define DIRECTION		@"direction"
#define PAGE			@"page"
#define TIME			@"time"

#ifdef MUPDF

static size_t getUsableMemoryAmount() {
	host_t host_port = mach_host_self();
	vm_statistics_data_t vm_stat;
	mach_msg_type_number_t host_size = sizeof(vm_stat) / sizeof(integer_t);
	if (host_statistics(host_port, HOST_VM_INFO, (host_info_t)&vm_stat, &host_size) == KERN_SUCCESS) {
		vm_size_t pagesize;
		if (host_page_size(host_port, &pagesize) == KERN_SUCCESS)
			return pagesize * (vm_stat.free_count + vm_stat.purgeable_count + vm_stat.inactive_count);
	}
	return FZ_STORE_DEFAULT;
}

static void lock_mutex(void *user, int lock) {
	assert(!pthread_mutex_lock(&((pthread_mutex_t *)user)[lock]));
}

static void unlock_mutex(void *user, int lock) {
	assert(!pthread_mutex_unlock(&((pthread_mutex_t *)user)[lock]));
}

#endif

@interface MyDocument () {
	struct timespec _mtimespec;
#ifdef MUPDF
	fz_locks_context _locks;
	pthread_mutex_t _mutex[FZ_LOCK_MAX];
#endif
}
@end

@implementation MyDocument

- (NSString *)windowNibName { return @"MyDocument"; }

- (void)refreshPDF {
	if (_pdf) [_view requestCursor];
	struct stat st;
	if (stat(_url.fileSystemRepresentation, &st)) {
		NSLog(@"stat error");
		return;
	}
	if (_mtimespec.tv_sec < st.st_mtimespec.tv_sec) {
#ifdef MUPDF
		fz_drop_document(_ctx, _pdf);
		_pdf = fz_open_document(_ctx, _url.fileSystemRepresentation);
#else
		CGPDFDocumentRelease(_pdf);
		_pdf = CGPDFDocumentCreateWithURL((__bridge CFURLRef)_url);
#endif
		if (_mtimespec.tv_sec) [_view refresh];
	}
	_mtimespec = st.st_mtimespec;
}

- (float)averageAspect {
	std::deque<NSSize> sizes;
	int n = [self pageCount];
	for (int i = 0; i < n; i++) sizes.push_back([self pageSize:i]);
	sort(sizes.begin(), sizes.end(), [](NSSize a, NSSize b){ return a.width < b.width; });
	if (n > 4) {
		sizes.pop_front();
		sizes.pop_front();
		sizes.pop_back();
		sizes.pop_back();
	}
	float w = 0, h = 0;
	for (NSSize size : sizes) {
		w += size.width;
		h += size.height;
	}
	return h / w;
}

- (BOOL)readFromURL:(NSURL *)absoluteURL ofType:(NSString *)typeName error:(NSError **)outError {
	NSArray *docs = [[NSDocumentController sharedDocumentController] documents];
	for (int i = 0; i < docs.count; i++) {
		NSArray *a = [docs[i] windowControllers];
		if (a.count) [[a[0] window] close];
    }
	self.url = absoluteURL;
#ifdef MUPDF
	for (int i = 0; i < FZ_LOCK_MAX; i++)
		assert(!pthread_mutex_init(&_mutex[i], NULL));
	_locks.user = _mutex;
	_locks.lock = lock_mutex;
	_locks.unlock = unlock_mutex;
	size_t size = getUsableMemoryAmount();
	printf("usable memory: %luMB\n", size >> 20);
	_ctx = fz_new_context(NULL, &_locks, size);
	fz_register_document_handlers(_ctx);
#endif
	[self refreshPDF];
	_aspect = [self averageAspect];
	NSUserDefaults *def = NSUserDefaults.standardUserDefaults;
	NSDictionary *settings = [def dictionaryForKey:SETTINGS];
	NSDictionary *docSettings = settings[_url.lastPathComponent];
	_cover = ![docSettings[NO_COVER] boolValue];
	_direction = [docSettings[DIRECTION] boolValue];
	[self setPage:[docSettings[PAGE] intValue]];
	return YES;
}

- (void)windowControllerDidLoadNib:(NSWindowController *)aController {
	_view.doc = self;
	[_view setupPrefetch];
}

- (void)savePref {
	if (_url) {
		NSUserDefaults *def = NSUserDefaults.standardUserDefaults;
		NSMutableDictionary *settings = [NSMutableDictionary dictionaryWithDictionary:[def dictionaryForKey:SETTINGS]];
		NSDictionary *docSettings = @{
									  FILEURL:_url.absoluteString,
									  NO_COVER:@(!_cover), DIRECTION:@(_direction), PAGE:@(_page), TIME:@(time(NULL))
									  };
		settings[_url.lastPathComponent] = docSettings;
		[def setObject:settings forKey:SETTINGS];
		[def synchronize];
	}
}

- (void)close {
	[NSCursor unhide];
	[self savePref];
	self.url = nil;
	[_view close];
#ifdef MUPDF
	fz_drop_document(_ctx, _pdf);
	fz_drop_context(_ctx);
#endif
    [super close];
}

- (NSSize)pageSize:(int)page {
#ifdef MUPDF
	fz_page *pdfPage = fz_load_page(_ctx, _pdf, page);
	fz_rect bbox = fz_bound_page(_ctx, pdfPage);
	fz_drop_page(_ctx, pdfPage);
	return NSMakeSize(bbox.x1 - bbox.x0, bbox.y1 - bbox.y0);
#else
	CGPDFPageRef pdfPage = CGPDFDocumentGetPage(_pdf, page + 1);
	NSSize size = CGPDFPageGetBoxRect(pdfPage, kCGPDFMediaBox).size;
	double th = -M_PI * CGPDFPageGetRotationAngle(pdfPage) / 180.;
	double w = cosf(th) * size.width - sinf(th) * size.height;
	double h = sinf(th) * size.width + cosf(th) * size.height;
	return NSMakeSize(fabs(w), fabs(h));
#endif
}

- (int)pageCount {
#ifdef MUPDF
	return fz_count_pages(_ctx, _pdf);
#else
	return (int)CGPDFDocumentGetNumberOfPages(_pdf);
#endif
}

- (void)setPage:(int)page {
	int pageCount = self.pageCount;
	if (page < 0) page = 0;
	else if (page >= pageCount) page = pageCount - 1;
	if (_cover ? page && !(page & 1) : page & 1) --page;
	_page = page;
}

- (IBAction)switchCover:(id)sender {
    _cover = !_cover;
	if (!_cover) _page++;
	[self setPage:_page];
	[_view refresh];
}

- (IBAction)switchDirection:(id)sender {
	_direction = !_direction;
	[_view refresh];
}

@end
