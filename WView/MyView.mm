#import "MyView.h"
#import "MyDocument.h"
#import "TimeMeasure.h"

enum {
	KEYCODE_SPACE = 49, KEYCODE_ESC = 53, KEYCODE_LEFT = 123, KEYCODE_RIGHT, KEYCODE_DOWN, KEYCODE_UP
};

enum Mode {
	MODE_MAIN, MODE_THUMB, MODE_PREFETCH
};

class Req {
	static constexpr double PURGE_DELAY = 1.;
public:
	Req() {}
#ifdef MUPDF
	Req(NSRect rect, int page, fz_context *ctx, int width, int height, bool regular) :
		_rect(rect), _page(page), _ctx(ctx), _width(width), _height(height), _regular(regular), _time(0.) {}
	void MakeDL(fz_document *pdf) {
		fz_page *pdfPage = fz_load_page(_ctx, pdf, _page);
		_bbox = fz_bound_page(_ctx, pdfPage);
		float w = _bbox.x1 - _bbox.x0, h = _bbox.y1 - _bbox.y0;
		float scale = std::min(fabs(_rect.size.width / w), fabs(_rect.size.height / h));
		_mtx = fz_scale(scale, scale);
		fz_rect rect = fz_transform_rect(_bbox, _mtx);
		_list = fz_new_display_list(_ctx, rect);
		fz_device *dev = fz_new_list_device(_ctx, _list);
		fz_run_page(_ctx, pdfPage, dev, fz_identity, nullptr);
		fz_close_device(_ctx, dev);
		fz_drop_device(_ctx, dev);
		fz_drop_page(_ctx, pdfPage);
		_pix = fz_new_pixmap_with_bbox(_ctx, fz_device_rgb(_ctx), fz_round_rect(rect), nullptr, 1);
		fz_clear_pixmap_with_value(_ctx, _pix, 0xff);
	}
	void Render() {
		fz_context *c = fz_clone_context(_ctx);
		fz_device *dev = fz_new_draw_device(c, _mtx, _pix);
		fz_run_display_list(c, _list, dev, fz_identity, _bbox, nullptr);
		fz_close_device(c, dev);
		fz_drop_device(c, dev);
		fz_drop_context(c);
		fz_drop_display_list(_ctx, _list);
		_list = nullptr;
	}
	void CopyAndDrop(uint32_t *bitmap) {
		int xofs = _rect.origin.x, yofs = _height - _pix->h - _rect.origin.y;
		for (int y = 0; y < _pix->h; y++)
			memcpy(&bitmap[_width * (y + yofs) + xofs], &_pix->samples[_pix->stride * y], _pix->w << 2);
		Drop();
	}
	void Drop() {
		fz_drop_pixmap(_ctx, _pix);
		_pix = nullptr;
	}
	void EndRender() { _time = PURGE_DELAY; }
	bool Rendered() const { return _time > 0.; }
	bool TestPurge(double time) { return _time > 0. && (_time -= time) <= 0.; }
#else
	Req(NSRect rect, int page) : _rect(rect), _page(page) {}
	void Render(CGPDFDocumentRef pdf, CGContextRef c) const {
		CGPDFPageRef pdfPage = CGPDFDocumentGetPage(pdf, _page + 1);
		CGContextSaveGState(c);
#if 1	//CGContextConcatCTMだと縮小はOKだが拡大してくれないので手動でSRTしている。
		NSSize size = CGPDFPageGetBoxRect(pdfPage, kCGPDFMediaBox).size;
		double th = -M_PI * CGPDFPageGetRotationAngle(pdfPage) / 180.;
		double w = cosf(th) * size.width - sinf(th) * size.height;
		double h = sinf(th) * size.width + cosf(th) * size.height;
		double m = std::min(fabs(_rect.size.width / w), fabs(_rect.size.height / h));
		CGContextTranslateCTM(c, _rect.origin.x + (w < 0. ? -w * m : 0.), _rect.origin.y + (h < 0. ? -h * m : 0.));
		CGContextRotateCTM(c, th);
		CGContextScaleCTM(c, m, m);
#else
		CGContextConcatCTM(c, CGPDFPageGetDrawingTransform(pdfPage, kCGPDFMediaBox, _rect, 0, YES));
#endif
		CGContextDrawPDFPage(c, pdfPage);
		CGContextRestoreGState(c);
	}
#endif
	int Eval(int mousePage, int docPage, int docPairPage, bool multi) {
		int r = 0;
		if (!multi ^ _regular) r += 10000;
		if (_regular) r += abs(_page - docPage);
		else if (_page != docPage && _page != docPairPage) r += abs(_page - mousePage);
		return r;
	}
	NSRect Rect() const { return _rect; }
	int Page(int d = 0) const { return _page - d; }
	bool IsRegular() const { return _regular; }
private:
	NSRect _rect;
	int _page;
	bool _regular;
#ifdef MUPDF
	fz_context *_ctx;
	fz_display_list *_list;
	fz_pixmap *_pix;
	fz_rect _bbox;
	fz_matrix _mtx;
	double _time;
	int _width, _height;
#endif
};

@interface MyView () {
	std::vector<Req> _q;
#ifdef MUPDF
	std::vector<Req> _qr;
	std::vector<Req> _qc;
	std::vector<int> _qp;
	dispatch_group_t _dg;
	int _renderN;
	bool _closing;
	int _keyDir;
	double _keyTimer;
#else
	CGContextRef _contextMain, _contextThumb;
#endif
	CGColorSpaceRef _colorSpace;
	uint32_t *_bitmapMain, *_bitmapThumb;
	int _width, _height;
	int _xn, _yn;
	BOOL _multi, _thumbFlag, _busy;
	int _mousePage;
}
- (void)update:(double)interval;
@end

static CVDisplayLinkRef sDisplayLink;
static CVReturn DisplayLinkCallback(CVDisplayLinkRef, const CVTimeStamp *now, const CVTimeStamp *, CVOptionFlags, CVOptionFlags *, void *context) {
	static std::atomic_flag f = ATOMIC_FLAG_INIT;
	if (!f.test_and_set())
		dispatch_async(dispatch_get_main_queue(), ^{
			if (sDisplayLink) [(__bridge MyView *)context update:(double)now->videoRefreshPeriod / now->videoTimeScale];
			f.clear();
		});
	return kCVReturnSuccess;
}

@implementation MyView

- (void)awakeFromNib {
	[self.window makeFirstResponder:self];
	[NSCursor hide];
	NSSize size = NSScreen.mainScreen.frame.size;
	_width = size.width;
	_height = size.height;
	_bitmapMain = new uint32_t[_width * _height];
	_bitmapThumb = new uint32_t[_width * _height];
	_colorSpace = CGColorSpaceCreateDeviceRGB();
#ifdef MUPDF
	[self setupRenderThread];
#else
	_contextMain = CGBitmapContextCreate(_bitmapMain, _width, _height, 8, 4 * _width, _colorSpace, kCGImageAlphaNoneSkipLast);
	_contextThumb = CGBitmapContextCreate(_bitmapThumb, _width, _height, 8, 4 * _width, _colorSpace, kCGImageAlphaNoneSkipLast);
#endif
	[self setWantsLayer:YES]; // improve frame rate
	self.layer.drawsAsynchronously = YES; // improve frame rate
	CVDisplayLinkCreateWithActiveCGDisplays(&sDisplayLink);
	CVDisplayLinkSetOutputCallback(sDisplayLink, DisplayLinkCallback, (__bridge void *)self);
	CVDisplayLinkStart(sDisplayLink);
}

- (void)close {
	CVDisplayLinkStop(sDisplayLink);
	CVDisplayLinkRelease(sDisplayLink);
	sDisplayLink = nullptr;
#ifdef MUPDF
	_closing = true;
	dispatch_group_wait(_dg, DISPATCH_TIME_FOREVER);
	for (Req &r : _qr) r.Drop();
	for (Req &r : _qc) r.Drop();
#else
	CGContextRelease(_contextMain);
	CGContextRelease(_contextThumb);
#endif
	CGColorSpaceRelease(_colorSpace);
	delete[] _bitmapMain;
	delete[] _bitmapThumb;
	[NSCursor unhide];
}

- (void)setupPrefetch {
#ifdef MUPDF
	if (_doc.pageCount <= PREFETCH_ALL_THRESHOLD)
		for (int i = 0; i < _doc.pageCount; i += !i && _doc.cover ? 1 : 2) _qp.push_back(i);
	else [self prefetch:_doc.page dir:false];
#endif
}

#ifdef MUPDF
- (void)setupRenderThread {
	int ncore;
	size_t len = sizeof(ncore);
	int selection[] = { CTL_HW, HW_NCPU };
	if (sysctl(selection, 2, &ncore, &len, nullptr, 0)) ncore = 1;
	_renderN = ncore;
	_dg = dispatch_group_create();
	for (int i = 0; i < ncore; i++) {
		dispatch_group_async(_dg, dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^() {
			while (!_closing) {
				bool f;
				Req req;
				@synchronized (self) {
					f = !_qr.empty();
					if (f) {
						req = [self pickup:_qr];
						if (req.IsRegular()) _qc.push_back(req);
					}
				}
				if (f) {
					req.Render();
					if (req.IsRegular()) @synchronized (self) {
						int page = req.Page();
						auto i = find_if(_qc.begin(), _qc.end(), [page](Req &r){ return !r.Page(page); });
						if (i != _qc.end()) i->EndRender();
					}
					else {
						req.CopyAndDrop(_bitmapThumb);
						dispatch_async(dispatch_get_main_queue(), ^{
							if (_multi) [self setNeedsDisplayInRect:req.Rect()];
						});
					}
				}
				else usleep(10000);
			}
		});
	}
}
#endif

- (Req)pickup:(std::vector<Req> &)q {
	int p0 = _doc.page, p1 = p0 + (_doc.cover ^ (p0 & 1) ? -1 : 1);
	auto i = min_element(q.begin(), q.end(), [=](Req &a, Req &b) {
		return a.Eval(_mousePage, p0, p1, _multi) < b.Eval(_mousePage, p0, p1, _multi);
	});
	Req r;
	if (i != q.end()) {
		r = *i;
		q.erase(i);
	}
	return r;
}

- (void)update:(double)interval {
	_mousePage = [self pt2page:self.window.mouseLocationOutsideOfEventStream];
#ifdef MUPDF
	for (int i = 0; i < _renderN && !_q.empty(); i++) {
		Req r = [self pickup:_q];
		r.MakeDL(_doc.pdf);
		@synchronized (self) {
			_qr.push_back(r);
		}
	}
	if (!_multi) {
		if (!_qp.empty() && (_q.size() + _qr.size()) < _renderN) {
			int page = _doc.page;
			auto i = min_element(_qp.begin(), _qp.end(), [page](int a, int b){ return abs(a - page) < abs(b - page); });
			[self drawSub:*i mode:MODE_PREFETCH];
			*i = _qp.back();
			_qp.pop_back();
		}
		if (_keyDir && (_keyTimer -= interval) <= 0. && !_busy) {
			_keyTimer = KEYREP2;
			[self pageMove:_doc.direction ? -_keyDir : _keyDir];
		}
	}
	@synchronized (self) {
		for (auto i = _qc.begin(); i != _qc.end();)
			if (i->TestPurge(interval)) {
				i->Drop();
				i = _qc.erase(i);
			}
			else i++;
	}
#else
	if (!_q.empty()) {
		Req r = [self pickup:_q];
		r.Render(_doc.pdf, _contextThumb);
		if (_multi) [self setNeedsDisplayInRect:r.Rect()];
	}
#endif
}

- (void)setupCursor {
	if (_multi) [NSCursor unhide];
	else [NSCursor hide];
}

- (void)requestCursor {
	dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), dispatch_get_main_queue(), ^{
		[self setupCursor];
	});
}

- (NSRect)getRect:(int)page {
	NSRect rect = self.bounds;
	if (_multi) {
		int index = (page + 1) / 2, x = index % _xn;
		if (!_doc.direction) x = _xn - 1 - x;
		rect.size = NSMakeSize(floor(rect.size.width / _xn), floor(rect.size.height / _yn));
		rect.origin = NSMakePoint(floor(x * rect.size.width), floor((_yn - 1 - index / _xn) * rect.size.height));
	}
	return rect;
}

- (void)drawSub:(int)page inRect:(NSRect)rect mode:(Mode)mode {
#ifdef MUPDF
	bool f = false;
	std::vector<Req>::iterator i;
	if (mode != MODE_THUMB) {
		i = find_if(_q.begin(), _q.end(), [page](Req &r){ return !r.Page(page) && r.IsRegular(); });
		f = i == _q.end();
		if (f) @synchronized (self) {
			f = find_if(_qr.begin(), _qr.end(), [page](Req &r){ return !r.Page(page) && r.IsRegular(); }) == _qr.end() &&
				find_if(_qc.begin(), _qc.end(), [page](Req &r){ return !r.Page(page); }) == _qc.end();
		}
	}
	if (mode == MODE_MAIN) {
		if (f) {
			Req req(rect, page, _doc.ctx, _width, _height, true);
			req.MakeDL(_doc.pdf);
			req.Render();
			req.CopyAndDrop(_bitmapMain);
		}
		else if (i != _q.end()) {
			i->MakeDL(_doc.pdf);
			@synchronized (self) {
				_qr.push_back(*i);
			}
			_q.erase(i);
		}
		while (!f) {
			@synchronized (self) {
				auto i = find_if(_qc.begin(), _qc.end(), [page](Req &r){ return !r.Page(page); });
				f = i != _qc.end() && i->Rendered();
				if (f) {
					i->CopyAndDrop(_bitmapMain);
					_qc.erase(i);
				}
			}
			if (!f) usleep(10000);
		}
	}
	else if (f || mode == MODE_THUMB) _q.emplace_back(rect, page, _doc.ctx, _width, _height, mode != MODE_THUMB);
#else
	Req req(rect, page);
	if (mode == MODE_THUMB) _q.push_back(req);
	else req.Render(_doc.pdf, _contextMain);
#endif
}

- (void)drawSub:(int)page mode:(Mode)mode {
	NSRect rect = [self getRect:page];
	size_t pageCount = _doc.pageCount;
	BOOL wf = _doc.cover ? page > 0 && (page < pageCount - 1 || pageCount & 1) : page < pageCount - 1;
	BOOL direction = _doc.direction;
	NSSize docSize, docSize0, docSize1;
	if (wf) {
		docSize0 = [_doc pageSize:page];
		docSize1 = [_doc pageSize:page + 1];
		docSize.width = std::max(docSize0.width, docSize1.width);
		docSize.height = std::max(docSize0.height, docSize1.height);
	}
	else docSize = [_doc pageSize:page];
	double docAspect = docSize.height / docSize.width;
	NSSize viewSize = rect.size;
	double viewAspect = viewSize.height / viewSize.width;
	if (wf) viewAspect *= 2.;
	if (viewAspect < docAspect) {
		double width = viewSize.height / docAspect;
		if (wf) {
			double x2 = .5 * rect.size.width;
			double x = rect.origin.x;
			double xratio = docSize0.width / docSize.width;
			rect.origin.x += direction ? x2 - width : x2 + (1. - xratio) * width;
			rect.size.width = xratio * width;
			[self drawSub:page inRect:rect mode:mode];
			xratio = docSize1.width / docSize.width;
			rect.origin.x = x + (direction ? x2 + (1. - xratio) * width : x2 - width);
			rect.size.width = xratio * width;
			[self drawSub:page + 1 inRect:rect mode:mode];
		}
		else {
			rect.origin.x += .5 * (rect.size.width - width);
			rect.size.width = width;
			[self drawSub:page inRect:rect mode:mode];
		}
	}
	else {
		double width = .5 * rect.size.width;
		if (wf) {
			double height = .5 * viewSize.width * docAspect;
			rect.origin.y += .5 * (rect.size.height - height);
			rect.size.height = height;
			double x = rect.origin.x;
			double xratio = docSize0.width / docSize.width;
			rect.size.width = xratio * width;
			rect.origin.x += direction ? 0. : (2. - xratio) * width;
			[self drawSub:page inRect:rect mode:mode];
			xratio = docSize1.width / docSize.width;
			rect.size.width = xratio * width;
			rect.origin.x = x + (direction ? (2. - xratio) * width : 0.);
			[self drawSub:page + 1 inRect:rect mode:mode];
		}
		else {
			double height = viewSize.width * docAspect;
			rect.origin.y += .5 * (rect.size.height - height);
			rect.size.height = height;
			[self drawSub:page inRect:rect mode:mode];
		}
	}
}

- (void)drawRect:(NSRect)rect {
	int bytes = 4 * _width * _height;
	if (!_multi) {
		memset(_bitmapMain, 0xff, bytes);
		[self drawSub:_doc.page mode:MODE_MAIN];
	}
	else if (!_thumbFlag) {
		_thumbFlag = TRUE;
		memset(_bitmapThumb, 0xff, bytes);
		NSSize size = self.bounds.size;
		double coef = .5 * _doc.aspect * size.width / size.height;
		bool cover = _doc.cover;
		int pageCount = _doc.pageCount, count = ((cover ? 2 : 1) + pageCount) / 2;
		for (_yn = 1; _xn = coef * _yn, _xn * _yn < count; _yn++)
			;
		int page = 0;
		for (int y = 0; y < _yn; y++)
			for (int x = 0; x < _xn; x++) {
				if (page < pageCount) [self drawSub:page mode:MODE_THUMB];
				page += !page && cover ? 1 : 2;
			}
	}
	CGDataProviderRef dpref = CGDataProviderCreateWithData(nullptr, _multi ? _bitmapThumb : _bitmapMain, bytes, nullptr);
	CGImageRef siref = CGImageCreate(_width, _height, 8, 32, 4 * _width, _colorSpace,
				kCGImageAlphaNoneSkipLast | kCGBitmapByteOrder32Big, dpref, nullptr, NO, kCGRenderingIntentDefault);
	CGContextDrawImage((CGContextRef)NSGraphicsContext.currentContext.graphicsPort, NSScreen.mainScreen.frame, siref);
	CGDataProviderRelease(dpref);
	CGImageRelease(siref);
	if (_multi) {
		[[NSColor.selectedControlColor colorWithAlphaComponent:.5] set];
		NSRectFillUsingOperation([self getRect:_doc.page], NSCompositeSourceOver);
	}
	_busy = FALSE;
	//static TM tm;tm.stop();tm.start();
}

- (void)refresh {
	_q.clear();
#ifdef MUPDF
	@synchronized (self) {
		for (Req &r : _qr) r.Drop();
		_qr.clear();
		for (Req &r : _qc) r.Drop();
		_qc.clear();
	}
#endif
	_thumbFlag = FALSE;
	[self setNeedsDisplay:TRUE];
}

- (void)prefetch:(int)page dir:(bool)dir {
#ifdef MUPDF
	if (_multi) return;
	for (int i = 0; i < _renderN; i += 2) {
		page += (dir ? -2 : 2) - (!page && _doc.cover ? 1 : 0);
		if (page >= 0 && page < _doc.pageCount) [self drawSub:page mode:MODE_PREFETCH];
	}
#endif
}

- (void)pageMove:(int)n {
	int page = _doc.page;
	[_doc setPage:page + 2 * n - (!page && _doc.cover ? 1 : 0)];
	[self prefetch:_doc.page dir:n == -1];
	if (page != _doc.page) {
		[self setNeedsDisplay:TRUE];
		_busy = TRUE;
	}
}

- (void)step:(int)dir {
	[self pageMove:_doc.direction ? -dir : dir];
#ifdef MUPDF
	_keyDir = dir;
	_keyTimer = KEYREP1;
#endif
}

- (int)pt2page:(NSPoint)pt {
	NSSize size = self.bounds.size;
	int x = (int)(pt.x / (size.width / _xn));
	if (!_doc.direction) x = _xn - 1 - x;
	int y = _yn - 1 - (int)(pt.y / (size.height / _yn));
	int page = 2 * (x + _xn * y) - (_doc.cover ? 1 : 0);
	if (page < 0) page = 0;
	return page;
}

- (void)setMulti:(BOOL)multi {
	_multi = multi;
	[self prefetch:_doc.page dir:false];
	[self setupCursor];
	[self setNeedsDisplay:TRUE];
}

- (void)keyDown:(NSEvent *)event {
#ifdef MUPDF
	bool f = !event.isARepeat;
#else
	bool f = true;
#endif
	switch (event.keyCode) {
		case KEYCODE_LEFT:
			if (_multi || f) [self step:1];
			break;
		case KEYCODE_RIGHT:
			if (_multi || f) [self step:-1];
			break;
		case KEYCODE_UP:
			if (_multi || !event.isARepeat) [self pageMove:_multi ? -_xn : -10000];
			break;
		case KEYCODE_DOWN:
			if (_multi || !event.isARepeat) [self pageMove:_multi ? _xn : 10000];
			break;
		case KEYCODE_SPACE:
			if (!event.isARepeat) [self setMulti:!_multi];
			break;
		case KEYCODE_ESC:
			if (!event.isARepeat) [self.window close];
			break;
	}
}

- (void)mouseDown:(NSEvent *)event {
	if (_multi) {
		int page = [self pt2page:event.locationInWindow];
		if (page < _doc.pageCount) {
			[_doc setPage:page];
			[self setMulti:FALSE];
		}
	}
	else [self step:1];
}

- (void)rightMouseDown:(NSEvent *)event {
	if (!_multi) [self step:-1];
}

- (void)otherMouseDown:(NSEvent *)event {
	[self setMulti:!_multi];
}

- (void)scrollWheel:(NSEvent *)event {
	if (!_busy) [self pageMove:[event deltaY] > 0 ? -1 : 1];
}

#ifdef MUPDF

- (void)keyUp:(NSEvent *)event {
	if ((event.keyCode == KEYCODE_LEFT && _keyDir > 0) || (event.keyCode == KEYCODE_RIGHT && _keyDir < 0)) _keyDir = 0;
}

- (void)mouseUp:(NSEvent *)event {
	if (_keyDir > 0) _keyDir = 0;
}

- (void)rightMouseUp:(NSEvent *)event {
	if (_keyDir < 0) _keyDir = 0;
}

#endif

@end
