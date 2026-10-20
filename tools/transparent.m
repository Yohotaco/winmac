// winmac-transparent.dylib — faz jogos "overlay" (ex.: How to Train Your Cock) funcionarem como no Windows:
//  1. fundo transparente: no Windows esses jogos usam DwmExtendFrameIntoClientArea e o alfa 0 vira transparente;
//     o Wine do macOS não faz isso e o fundo fica preto. Aqui a janela Cocoa e a camada Metal ficam não opacas.
//  2. sempre por cima de todos os apps, em todos os Spaces (inclusive apps em tela cheia; para isso o processo
//     vira um app "acessório", sem ícone no Dock nem no Cmd+Tab, como um overlay).
//  3. cliques atravessam as partes transparentes: o módulo lê o alfa do pixel embaixo do mouse no último quadro
//     desenhado; se for transparente, a janela ignora o mouse e o clique vai para o app de trás.
// Carregado via DYLD_INSERT_LIBRARIES; só age nos processos cujo .exe está em WINMAC_TRANSPARENT_EXES (':').
#import <Foundation/Foundation.h>
#import <QuartzCore/QuartzCore.h>
#import <Metal/Metal.h>
#import <objc/runtime.h>
#import <objc/message.h>
#include <crt_externs.h>
#include <mach-o/dyld.h>

static FILE *dbg;

// ---------- último quadro desenhado ----------
// A MoltenVK pede um drawable novo a cada quadro. O drawable pedido agora ainda vai ser desenhado,
// então o "último quadro pronto" é o do pedido anterior.
static id<MTLTexture> pendingTex, lastTex;
static id (*orig_nextDrawable)(id, SEL);
static id my_nextDrawable(id self, SEL _cmd) {
    id drawable = orig_nextDrawable(self, _cmd);
    @synchronized ([CAMetalLayer class]) {
        lastTex = pendingTex;
        pendingTex = [drawable texture];
    }
    return drawable;
}

static void hook_metal(void) {
    Method m = class_getInstanceMethod([CAMetalLayer class], @selector(nextDrawable));
    orig_nextDrawable = (void *)method_setImplementation(m, (IMP)my_nextDrawable);
}

// Alfa (0–255) do pixel do último quadro, ou -1 se não der para ler
static int alpha_at(double fx, double fy) {
    id<MTLTexture> tex;
    @synchronized ([CAMetalLayer class]) { tex = lastTex; }
    if (!tex || tex.framebufferOnly) return -1;
    MTLPixelFormat f = tex.pixelFormat;
    if (f != MTLPixelFormatBGRA8Unorm && f != MTLPixelFormatBGRA8Unorm_sRGB &&
        f != MTLPixelFormatRGBA8Unorm && f != MTLPixelFormatRGBA8Unorm_sRGB) return -1;
    NSUInteger x = (NSUInteger)(fx * tex.width), y = (NSUInteger)(fy * tex.height);
    if (x >= tex.width || y >= tex.height) return -1;
    static id<MTLCommandQueue> queue; static id<MTLBuffer> buf;
    if (!queue || queue.device != tex.device) {
        queue = [tex.device newCommandQueue];
        buf = [tex.device newBufferWithLength:4 options:MTLResourceStorageModeShared];
    }
    id<MTLCommandBuffer> cb = [queue commandBuffer];
    id<MTLBlitCommandEncoder> blit = [cb blitCommandEncoder];
    [blit copyFromTexture:tex sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(x, y, 0) sourceSize:MTLSizeMake(1, 1, 1)
                 toBuffer:buf destinationOffset:0 destinationBytesPerRow:4 destinationBytesPerImage:4];
    [blit endEncoding];
    [cb commit];
    [cb waitUntilCompleted];
    return ((uint8_t *)buf.contents)[3];
}

// ---------- aparência da janela ----------
static void make_layers_clear(CALayer *layer) {
    if (!layer) return;
    if ([layer isKindOfClass:[CAMetalLayer class]]) {
        CAMetalLayer *ml = (CAMetalLayer *)layer;
        ml.opaque = NO;
        ml.framebufferOnly = NO;   // permite ler o pixel embaixo do mouse
    }
    layer.backgroundColor = NULL;
    for (CALayer *sub in layer.sublayers) make_layers_clear(sub);
}

static void make_views_clear(id view) {
    if (!view) return;
    [view setValue:@YES forKey:@"wantsLayer"];
    make_layers_clear([view valueForKey:@"layer"]);
    for (id sub in [view valueForKey:@"subviews"]) make_views_clear(sub);
}

static NSArray *visible_windows(void) {
    id app = [NSClassFromString(@"NSApplication") valueForKey:@"sharedApplication"];
    NSMutableArray *out = [NSMutableArray array];
    for (id w in [app valueForKey:@"windows"]) if ([[w valueForKey:@"visible"] boolValue]) [out addObject:w];
    return out;
}

// A cada 0,5 s: transparência, nível e Spaces (o Wine às vezes desfaz)
static void style_tick(void) {
    // App "acessório" (sem Dock/Cmd+Tab): só assim o macOS deixa a janela aparecer por cima de apps em
    // tela cheia de outros apps. O Wine volta para "normal" quando mostra janelas, então é reaplicado aqui.
    id app = [NSClassFromString(@"NSApplication") valueForKey:@"sharedApplication"];
    long policy = ((long (*)(id, SEL))objc_msgSend)(app, sel_registerName("activationPolicy"));
    if (policy != 1) {
        ((BOOL (*)(id, SEL, long))objc_msgSend)(app, sel_registerName("setActivationPolicy:"), 1);
        if (dbg) fprintf(dbg, "modo acessório (era %ld)\n", policy);
        for (id w in visible_windows()) [w performSelector:@selector(orderFrontRegardless)];
    }
    id clear = [NSClassFromString(@"NSColor") valueForKey:@"clearColor"];
    for (id w in visible_windows()) {
        @try {
            [w setValue:@NO forKey:@"opaque"];
            [w setValue:clear forKey:@"backgroundColor"];
            [w setValue:@NO forKey:@"hasShadow"];
            make_views_clear([w valueForKey:@"contentView"]);
            [w setValue:@(25) forKey:@"level"];                    // NSStatusWindowLevel: acima dos apps
            NSUInteger want = (1 << 0) | (1 << 4) | (1 << 8);      // canJoinAllSpaces | stationary | fullScreenAuxiliary
            if ([[w valueForKey:@"collectionBehavior"] unsignedIntegerValue] != want) {
                [w setValue:@(want) forKey:@"collectionBehavior"];
                // O macOS só leva a janela para os outros Spaces quando ela é reapresentada
                [w performSelector:@selector(orderFrontRegardless)];
                if (dbg) fprintf(dbg, "janela em todos os Spaces\n");
            }
        } @catch (NSException *e) {
            if (dbg) fprintf(dbg, "erro: %s\n", e.reason.UTF8String);
        }
    }
    if (dbg) fflush(dbg);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 500 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{ style_tick(); });
}

// A cada ~30 ms: cliques só pegam no jogo onde o pixel não é transparente.
// Se não der para ler o pixel, deixa o clique passar (nunca prende a tela do usuário).
static void mouse_tick(void) {
    @try {
        NSPoint p = [[NSClassFromString(@"NSEvent") valueForKey:@"mouseLocation"] pointValue];
        for (id w in visible_windows()) {
            NSRect fr = [[w valueForKey:@"frame"] rectValue];
            BOOL ignore = YES;
            if (NSPointInRect(p, fr)) {
                int a = alpha_at((p.x - fr.origin.x) / fr.size.width, 1.0 - (p.y - fr.origin.y) / fr.size.height);
                ignore = a < 8;   // inclui -1 (não deu para ler)
            }
            if ([[w valueForKey:@"ignoresMouseEvents"] boolValue] != ignore)
                [w setValue:@(ignore) forKey:@"ignoresMouseEvents"];
        }
    } @catch (NSException *e) {
        if (dbg) fprintf(dbg, "erro mouse: %s\n", e.reason.UTF8String);
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 30 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{ mouse_tick(); });
}

static BOOL is_target(void) {
    const char *list = getenv("WINMAC_TRANSPARENT_EXES");
    if (!list || !*list) return NO;
    // O Wine reescreve o argv com o caminho do .exe do Windows, então lê o argv atual
    NSMutableString *cmd = [NSMutableString string];
    char **argv = *_NSGetArgv();
    for (int i = 0; i < *_NSGetArgc(); i++) if (argv[i]) [cmd appendFormat:@"%s ", argv[i]];
    [cmd setString:cmd.lowercaseString];
    for (NSString *exe in [@(list) componentsSeparatedByString:@":"])
        if (exe.length && [cmd containsString:exe.lowercaseString]) return YES;
    return NO;
}

// O macOS só deixa uma janela aparecer sobre apps em tela cheia de outros apps se o app já
// "nasceu" acessório. O Wine se declara app normal ao mostrar a primeira janela; aqui essa chamada
// vira "acessório" no processo do jogo. O gancho é instalado assim que o AppKit é carregado.
static BOOL (*orig_setActivationPolicy)(id, SEL, long);
static BOOL my_setActivationPolicy(id self, SEL _cmd, long policy) {
    if (policy == 0 && is_target()) policy = 1;
    return orig_setActivationPolicy(self, _cmd, policy);
}
static void on_image_added(const struct mach_header *mh, intptr_t slide) {
    static BOOL hooked;
    if (hooked) return;
    Class cls = objc_getClass("NSApplication");
    if (!cls) return;
    hooked = YES;
    Method m = class_getInstanceMethod(cls, sel_registerName("setActivationPolicy:"));
    if (m) orig_setActivationPolicy = (void *)method_setImplementation(m, (IMP)my_setActivationPolicy);
}

__attribute__((constructor)) static void init(void) {
    @autoreleasepool {
        const char *list = getenv("WINMAC_TRANSPARENT_EXES");
        if (!list || !*list) return;
        _dyld_register_func_for_add_image(on_image_added);
        // Espera o Wine trocar o argv e abrir a janela antes de decidir
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
            BOOL target = is_target();
            if (getenv("WINMAC_DEBUG")) { dbg = fopen("/tmp/winmac-transparent.log", "a"); if (dbg) fprintf(dbg, "target=%d\n", target); }
            if (!target) { if (dbg) { fclose(dbg); dbg = NULL; } return; }
            hook_metal();
            style_tick();
            mouse_tick();
        });
    }
}
