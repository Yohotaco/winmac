// winmac-dxmt.dylib — deixa o DXMT (DirectX 11 → Metal, código aberto) funcionar no Wine Staging.
// O DXMT pede ao Wine uma "tela Metal" dentro da janela do jogo através do símbolo macdrv_functions,
// que o Wine do CrossOver exporta e o Wine comum não. Este módulo exporta esse símbolo e implementa as
// funções usando as classes do próprio Wine (WineWindow, WineContentView, WineMetalView).
// Carregado via DYLD_INSERT_LIBRARIES; não faz nada até o DXMT chamar.
#import <AppKit/AppKit.h>
#import <QuartzCore/QuartzCore.h>
#import <Metal/Metal.h>
#import <objc/runtime.h>
#import <objc/message.h>

struct macdrv_win_data { void *hwnd, *cocoa_window, *cocoa_view, *client_cocoa_view; };

static void on_main_thread(dispatch_block_t b) {
    if ([NSThread isMainThread]) b(); else dispatch_sync(dispatch_get_main_queue(), b);
}

static void *window_hwnd(id w) {
    Ivar iv = class_getInstanceVariable(object_getClass(w), "hwnd");
    return iv ? *(void **)((char *)(__bridge void *)w + ivar_getOffset(iv)) : NULL;
}

static double area(NSView *v) { NSRect r = v.bounds; return r.size.width * r.size.height; }

// A área do cliente: a maior WineContentView dentro da janela (ou a própria contentView)
static NSView *client_view(NSWindow *w) {
    NSView *best = w.contentView;
    Class wcv = NSClassFromString(@"WineContentView");
    for (NSView *sub in w.contentView.subviews)
        if ((!wcv || [sub isKindOfClass:wcv]) && area(sub) > area(best) * 0.5) best = sub;
    return best;
}

static struct macdrv_win_data *get_win_data(void *hwnd) {
    struct macdrv_win_data *d = calloc(1, sizeof(*d));
    d->hwnd = hwnd;
    on_main_thread(^{
        NSWindow *found = nil, *largest = nil;
        for (NSWindow *w in [NSClassFromString(@"NSApplication") sharedApplication].windows) {
            if (window_hwnd(w) == hwnd) { found = w; break; }
            if (w.visible && (!largest || area(w.contentView) > area(largest.contentView))) largest = w;
        }
        if (!found) found = largest;   // janela filha: usa a janela principal do jogo
        if (found) {
            d->cocoa_window = (__bridge void *)found;
            d->cocoa_view = (__bridge void *)found.contentView;
            d->client_cocoa_view = (__bridge void *)client_view(found);
        }
    });
    return d;
}

static void release_win_data(struct macdrv_win_data *d) { free(d); }

static void *create_metal_view(void *v, void *device) {
    if (!v) return NULL;
    __block void *ret = NULL;
    on_main_thread(^{
        NSView *view = (__bridge NSView *)v;
        id<MTLDevice> dev = device ? (__bridge id<MTLDevice>)device : MTLCreateSystemDefaultDevice();
        NSView *mv = nil;
        SEL sel = sel_registerName("newMetalViewWithDevice:");
        if ([view respondsToSelector:sel]) {
            mv = (__bridge_transfer NSView *)((void *(*)(id, SEL, id))objc_msgSend)(view, sel, dev);
        } else {
            mv = [[NSClassFromString(@"NSView") alloc] initWithFrame:view.bounds];
            CAMetalLayer *layer = [CAMetalLayer layer];
            layer.device = dev;
            mv.layer = layer;
            mv.wantsLayer = YES;
            mv.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
            [view addSubview:mv];
        }
        if (mv) {
            CALayer *l = mv.layer;
            if ([l isKindOfClass:[CAMetalLayer class]]) {
                ((CAMetalLayer *)l).device = dev;
                l.contentsScale = view.window.backingScaleFactor ?: 1;
            }
            ret = (__bridge_retained void *)mv;
        }
    });
    return ret;
}

static void *get_metal_layer(void *v) {
    __block void *ret = NULL;
    on_main_thread(^{ ret = (__bridge void *)((__bridge NSView *)v).layer; });
    return ret;
}

static void release_metal_view(void *v) {
    if (!v) return;
    on_main_thread(^{
        NSView *mv = (__bridge_transfer NSView *)v;
        [mv removeFromSuperview];
    });
}

static void *create_metal_device(void) { return (__bridge_retained void *)MTLCreateSystemDefaultDevice(); }
static void release_metal_device(void *d) { if (d) CFRelease(d); }

// Mesma ordem de campos do Wine do CrossOver (ver src/winemetal/unix/winemetal_unix.c no DXMT)
struct macdrv_functions_t {
    void (*macdrv_init_display_devices)(BOOL);
    struct macdrv_win_data *(*get_win_data)(void *hwnd);
    void (*release_win_data)(struct macdrv_win_data *data);
    void *(*macdrv_get_cocoa_window)(void *hwnd, BOOL require_on_screen);
    void *(*macdrv_create_metal_device)(void);
    void (*macdrv_release_metal_device)(void *d);
    void *(*macdrv_view_create_metal_view)(void *v, void *d);
    void *(*macdrv_view_get_metal_layer)(void *v);
    void (*macdrv_view_release_metal_view)(void *v);
    void (*on_main_thread)(dispatch_block_t b);
    void *reserved[16];
};

__attribute__((visibility("default")))
struct macdrv_functions_t macdrv_functions = {
    .get_win_data = get_win_data,
    .release_win_data = release_win_data,
    .macdrv_create_metal_device = create_metal_device,
    .macdrv_release_metal_device = release_metal_device,
    .macdrv_view_create_metal_view = create_metal_view,
    .macdrv_view_get_metal_layer = get_metal_layer,
    .macdrv_view_release_metal_view = release_metal_view,
    .on_main_thread = on_main_thread,
};
