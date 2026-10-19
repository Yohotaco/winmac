// winmac-transparent.dylib — deixa transparentes as janelas de jogos "overlay" (ex.: How to Train Your Cock).
// No Windows esses jogos usam DwmExtendFrameIntoClientArea e o fundo com alfa 0 vira transparente.
// O Wine do macOS não faz isso, então o fundo fica preto. Este módulo é carregado no processo do jogo
// (DYLD_INSERT_LIBRARIES) e torna a janela Cocoa e a camada Metal não opacas.
// Só age nos processos cujo .exe está em WINMAC_TRANSPARENT_EXES (nomes separados por ':').
#import <Foundation/Foundation.h>
#import <QuartzCore/QuartzCore.h>
#include <crt_externs.h>

static FILE *dbg;
static void make_layers_clear(CALayer *layer) {
    if (!layer) return;
    if (dbg) fprintf(dbg, "  layer %s opaque=%d\n", NSStringFromClass(layer.class).UTF8String, layer.opaque);
    if ([layer isKindOfClass:NSClassFromString(@"CAMetalLayer")]) layer.opaque = NO;
    layer.backgroundColor = NULL;
    for (CALayer *sub in layer.sublayers) make_layers_clear(sub);
}

static void make_views_clear(id view) {
    if (!view) return;
    if (dbg) fprintf(dbg, " view %s\n", NSStringFromClass([view class]).UTF8String);
    [view setValue:@YES forKey:@"wantsLayer"];
    make_layers_clear([view valueForKey:@"layer"]);
    for (id sub in [view valueForKey:@"subviews"]) make_views_clear(sub);
}

static void tick(void) {
    id app = [NSClassFromString(@"NSApplication") valueForKey:@"sharedApplication"];
    id clear = [NSClassFromString(@"NSColor") valueForKey:@"clearColor"];
    for (id w in [app valueForKey:@"windows"]) {
        if (![[w valueForKey:@"visible"] boolValue]) continue;
        if (dbg) fprintf(dbg, "window %s\n", NSStringFromClass([w class]).UTF8String);
        [w setValue:@NO forKey:@"opaque"];
        [w setValue:clear forKey:@"backgroundColor"];
        [w setValue:@NO forKey:@"hasShadow"];
        make_views_clear([w valueForKey:@"contentView"]);
    }
    static int n; if (dbg && ++n > 40) { fclose(dbg); dbg = NULL; } else if (dbg) fflush(dbg);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 500 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{ tick(); });
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

__attribute__((constructor)) static void init(void) {
    @autoreleasepool {
        const char *list = getenv("WINMAC_TRANSPARENT_EXES");
        if (!list || !*list) return;
        // Espera o Wine trocar o argv e abrir a janela antes de decidir
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
            if (getenv("WINMAC_DEBUG")) { dbg = fopen("/tmp/winmac-transparent.log", "a"); if (dbg) fprintf(dbg, "target=%d\n", is_target()); }
            if (is_target()) tick(); else if (dbg) { fclose(dbg); dbg = NULL; }
        });
    }
}
