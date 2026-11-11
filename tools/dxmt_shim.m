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
#include <crt_externs.h>
#include <spawn.h>

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

// Papel de parede animado (Wallpaper Engine): ele desenha numa janela filha da "WorkerW" da área de
// trabalho, que pertence a outro processo (winmac-progman.exe). Sem janela Cocoa aqui, este processo ganha
// a sua própria, do tamanho da tela, no nível do papel de parede do macOS: atrás de tudo e dos ícones.
static BOOL is_wallpaper_process(void) {
    static int cached = -1;
    if (cached < 0) {
        cached = 0;
        char **argv = *_NSGetArgv();
        for (int i = 0; i < *_NSGetArgc(); i++)
            if (argv[i] && (strcasestr(argv[i], "wallpaper64.exe") || strcasestr(argv[i], "wallpaper32.exe"))) cached = 1;
    }
    return cached;
}

// A barra de menus do macOS 26 tira a cor do véu da foto de fundo (não do que está desenhado em cima dela).
// Com uma foto clara ela fica com uma faixa branca por cima do papel de parede animado. Por isso, enquanto o
// Wallpaper Engine roda, a foto de fundo vira a prévia do papel de parede escolhido; ao fechar, volta a original.
static NSString *winmac_dir(void) { return [NSHomeDirectory() stringByAppendingPathComponent:@"winmac"]; }
static NSString *original_file(void) { return [winmac_dir() stringByAppendingPathComponent:@"wallpaper-original.txt"]; }

static void set_desktop_picture(NSURL *url) {
    for (NSScreen *s in NSScreen.screens)
        [[NSWorkspace sharedWorkspace] setDesktopImageURL:url forScreen:s options:@{} error:nil];
}

// A foto de fundo é por Space: num app em tela cheia a troca não vale para a mesa. O Dock mostra a
// "Fullscreen Backdrop" (um nível acima do papel de parede) só nos Spaces de tela cheia.
static BOOL on_fullscreen_space(void) {
    BOOL full = NO;
    CFArrayRef list = CGWindowListCopyWindowInfo(kCGWindowListOptionOnScreenOnly, kCGNullWindowID);
    for (NSDictionary *w in (__bridge NSArray *)list)
        if ([w[(id)kCGWindowLayer] intValue] == CGWindowLevelForKey(kCGDesktopWindowLevelKey) + 1 &&
            [w[(id)kCGWindowOwnerName] isEqual:@"Dock"]) full = YES;
    if (list) CFRelease(list);
    return full;
}

// Na saída, um processo à parte devolve a foto original assim que a mesa normal estiver na frente
// (desiste se outro Wallpaper Engine abrir). Só ele apaga o arquivo com a original.
static void restore_desktop_picture(void) {
    NSString *orig = [NSString stringWithContentsOfFile:original_file() encoding:NSUTF8StringEncoding error:nil];
    if (!orig.length || [orig containsString:@"'"]) return;
    NSString *js = [NSString stringWithFormat:
        @"ObjC.import('AppKit');ObjC.import('CoreGraphics');delay(3);"
        "for(var i=0;i<86400;i++){var a=ObjC.deepUnwrap(ObjC.castRefToObject($.CGWindowListCopyWindowInfo(1,0)))||[];"
        "if(a.some(w=>w.kCGWindowOwnerName=='wine'&&w.kCGWindowLayer==%d))break;"
        "if(!a.some(w=>w.kCGWindowOwnerName=='Dock'&&w.kCGWindowLayer==%d)){var u=$.NSURL.URLWithString('%@'),s=$.NSScreen.screens;"
        "for(var j=0;j<s.count;j++)$.NSWorkspace.sharedWorkspace.setDesktopImageURLForScreenOptionsError(u,s.objectAtIndex(j),$({}),null);"
        "$.NSFileManager.defaultManager.removeItemAtPathError('%@',null);break;}delay(1);}",
        CGWindowLevelForKey(kCGDesktopWindowLevelKey), CGWindowLevelForKey(kCGDesktopWindowLevelKey) + 1, orig, original_file()];
    pid_t pid;
    char *args[] = {"/usr/bin/osascript", "-l", "JavaScript", "-e", (char *)js.UTF8String, NULL};
    char *env[] = {"PATH=/usr/bin:/bin", NULL};
    posix_spawn(&pid, args[0], NULL, NULL, args, env);
}

static NSURL *pending_preview;
static NSWindow *wp_win;
static void apply_preview(void) {
    if (!pending_preview || on_fullscreen_space()) return;
    // Guarda a foto original uma vez só (se o Wallpaper Engine fechar à força, ela continua guardada)
    NSURL *current = [[NSWorkspace sharedWorkspace] desktopImageURLForScreen:NSScreen.screens.firstObject];
    if ([current.path isEqual:pending_preview.path]) { pending_preview = nil; return; }   // já está
    if (current && ![current.path hasPrefix:[winmac_dir() stringByAppendingPathComponent:@"wallpaper-preview-"]] &&
        ![NSFileManager.defaultManager fileExistsAtPath:original_file()])
        [current.absoluteString writeToFile:original_file() atomically:YES encoding:NSUTF8StringEncoding error:nil];
    // A barra de menus só recalcula a cor com a foto à vista: esconde a janela por um instante
    // (quase não se nota, a foto nova é a prévia do mesmo papel de parede)
    BOOL shown = wp_win.visible;
    if (shown) [wp_win orderOut:nil];
    set_desktop_picture(pending_preview);
    pending_preview = nil;
    if (shown) dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        [wp_win orderFrontRegardless]; });
}

static void match_desktop_picture(void) {
    const char *prefix = getenv("WINEPREFIX");
    if (!prefix) return;
    NSString *drive = [@(prefix) stringByAppendingPathComponent:@"drive_c"];
    NSData *json = [NSData dataWithContentsOfFile:[NSFileManager.defaultManager.currentDirectoryPath
                                                    stringByAppendingPathComponent:@"config.json"]];
    if (!json) json = [NSData dataWithContentsOfFile:[drive stringByAppendingPathComponent:
                        @"Program Files (x86)/Steam/steamapps/common/wallpaper_engine/config.json"]];
    NSDictionary *cfg = json ? [NSJSONSerialization JSONObjectWithData:json options:0 error:nil] : nil;
    if (![cfg isKindOfClass:NSDictionary.class]) return;
    NSString *project = nil;
    for (NSDictionary *user in cfg.allValues) {
        if (![user isKindOfClass:NSDictionary.class]) continue;
        id sel = [user valueForKeyPath:@"general.wallpaperconfig.selectedwallpapers"];
        if (![sel isKindOfClass:NSDictionary.class]) continue;
        id file = [sel[@"Monitor0"] isKindOfClass:NSDictionary.class] ? sel[@"Monitor0"][@"file"] : nil;
        if ([file isKindOfClass:NSString.class]) project = file;
    }
    if (project.length < 3) return;
    // "C:/Program Files (x86)/..." → <bottle>/drive_c/Program Files (x86)/...
    project = [drive stringByAppendingPathComponent:[[project substringFromIndex:3] stringByReplacingOccurrencesOfString:@"\\" withString:@"/"]];
    NSDictionary *proj = [NSJSONSerialization JSONObjectWithData:[NSData dataWithContentsOfFile:project] ?: [NSData data] options:0 error:nil];
    NSString *preview = [proj isKindOfClass:NSDictionary.class] ? proj[@"preview"] : nil;
    if (![preview isKindOfClass:NSString.class]) return;
    NSImage *img = [[NSImage alloc] initWithContentsOfFile:[project.stringByDeletingLastPathComponent stringByAppendingPathComponent:preview]];
    CGImageRef cg = [img CGImageForProposedRect:NULL context:nil hints:nil];
    if (!cg) return;
    NSData *png = [[[NSBitmapImageRep alloc] initWithCGImage:cg] representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
    // Um nome por papel de parede: com o mesmo nome o macOS não percebe a troca
    NSString *dest = [winmac_dir() stringByAppendingPathComponent:[NSString stringWithFormat:@"wallpaper-preview-%@.png",
                      project.stringByDeletingLastPathComponent.lastPathComponent]];
    if (![png writeToFile:dest atomically:YES]) return;
    pending_preview = [NSURL fileURLWithPath:dest];
    static id observer;
    if (!observer)   // em tela cheia: troca quando a mesa normal vier para a frente
        observer = [NSWorkspace.sharedWorkspace.notificationCenter addObserverForName:NSWorkspaceActiveSpaceDidChangeNotification
                     object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *n) {
                         dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), dispatch_get_main_queue(), ^{ apply_preview(); }); }];
    apply_preview();
}

static NSWindow *wallpaper_window(void) {
    match_desktop_picture();   // a cada janela nova: pega a troca de papel de parede no Wallpaper Engine
    if (wp_win) return wp_win;
    atexit(restore_desktop_picture);
    NSScreen *screen = NSScreen.screens.firstObject;
    wp_win = [[NSWindow alloc] initWithContentRect:screen.frame styleMask:NSWindowStyleMaskBorderless
                                        backing:NSBackingStoreBuffered defer:NO];
    wp_win.releasedWhenClosed = NO;
    wp_win.level = CGWindowLevelForKey(kCGDesktopWindowLevelKey);   // nível da foto do fundo: atrás dos ícones da mesa
    wp_win.collectionBehavior = NSWindowCollectionBehaviorCanJoinAllSpaces | NSWindowCollectionBehaviorStationary |
                             NSWindowCollectionBehaviorIgnoresCycle;
    wp_win.ignoresMouseEvents = YES;
    wp_win.hasShadow = NO;
    wp_win.backgroundColor = NSColor.blackColor;
    wp_win.title = @"WinMac Wallpaper Engine";
    wp_win.contentView.wantsLayer = YES;
    [wp_win orderFrontRegardless];
    return wp_win;
}

// Papel de parede sem som: o áudio do Wine sai por uma AudioUnit do macOS; no processo do Wallpaper Engine
// ela começa com volume zero. Nos outros processos (Steam, jogos) não muda nada.
#include <AudioToolbox/AudioToolbox.h>
static OSStatus muted_start(AudioUnit unit) {
    if (is_wallpaper_process()) {
        OSStatus err = AudioUnitSetParameter(unit, kHALOutputParam_Volume, kAudioUnitScope_Global, 0, 0.0f, 0);
        AudioUnitParameterValue vol = -1;
        AudioUnitGetParameter(unit, kHALOutputParam_Volume, kAudioUnitScope_Global, 0, &vol);
        FILE *f = fopen([winmac_dir() stringByAppendingPathComponent:@"wallpaper.log"].fileSystemRepresentation, "a");
        if (f) { fprintf(f, "Wallpaper Engine sem som (status %d, volume %.2f)\n", (int)err, vol); fclose(f); }
    }
    return AudioOutputUnitStart(unit);
}
__attribute__((used, section("__DATA,__interpose")))
static const struct { const void *replacement, *original; } interpose_start = { (const void *)muted_start, (const void *)AudioOutputUnitStart };

static struct macdrv_win_data *get_win_data(void *hwnd) {
    struct macdrv_win_data *d = calloc(1, sizeof(*d));
    d->hwnd = hwnd;
    on_main_thread(^{
        NSWindow *found = nil, *largest = nil;
        for (NSWindow *w in [NSClassFromString(@"NSApplication") sharedApplication].windows) {
            if (window_hwnd(w) == hwnd) { found = w; break; }
            if (w.visible && (!largest || area(w.contentView) > area(largest.contentView))) largest = w;
        }
        if (!found && is_wallpaper_process()) found = wallpaper_window();
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
