// winmac-fg: gera quadros extras para os jogos do WinMac, no estilo do Lossless Scaling do Windows.
//
// O Lossless Scaling não roda no Wine: ele captura a tela com funções que só o Windows tem (DXGI Desktop
// Duplication / Windows Graphics Capture) e fecha ao abrir. Aqui o próprio macOS faz o mesmo trabalho:
//  1. o ScreenCaptureKit captura só a janela do jogo, mesmo que outra janela esteja por cima dela;
//  2. o interpolador de baixa latência do VideoToolbox (macOS 26 ou mais novo) cria os quadros entre dois
//     quadros reais. Ele roda no Neural Engine, então não disputa a GPU com o jogo;
//  3. uma janela que deixa o mouse passar, por cima do jogo, mostra os quadros reais e os gerados
//     alternados, no ritmo da tela. O mouse e o teclado continuam indo para o jogo, que fica embaixo.
//
// Uso: winmac-fg [--now | --window <id>]
//   Fica na barra de menus. Control+Option+S (o atalho do Lossless Scaling) liga e desliga no jogo da frente.
//   --now liga na janela da frente depois de 3 segundos; --window liga numa janela específica (testes).
// Ajustes em ~/winmac/framegen.conf (multiplier=2|3|4, fps=0|1). SIGHUP relê o arquivo.
//
// Compilar: swiftc -O -swift-version 5 -target arm64-apple-macos26.0 tools/framegen.swift -o tools/winmac-fg

import AppKit
import Carbon.HIToolbox
import CoreMedia
import CoreVideo
import QuartzCore
import ScreenCaptureKit
import VideoToolbox

setvbuf(stdout, nil, _IOLBF, 0)
func log(_ s: String) {
    let f = DateFormatter(); f.dateFormat = "HH:mm:ss"
    print("[\(f.string(from: Date()))] \(s)")
}

let debug = ProcessInfo.processInfo.environment["WINMAC_FG_DEBUG"] != nil
let home = FileManager.default.homeDirectoryForCurrentUser.path
let configPath = "\(home)/winmac/framegen.conf"

struct Settings {
    var multiplier = 2
    var showFPS = true

    static func load() -> Settings {
        var s = Settings()
        let text = (try? String(contentsOfFile: configPath, encoding: .utf8)) ?? ""
        for line in text.split(separator: "\n") {
            let kv = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard kv.count == 2 else { continue }
            switch kv[0] {
            case "multiplier":
                if let m = Int(kv[1].replacingOccurrences(of: "x", with: "")), (2...4).contains(m) { s.multiplier = m }
            case "fps": s.showFPS = kv[1] != "0"
            default: break
            }
        }
        return s
    }

    func save() {
        try? "multiplier=\(multiplier)\nfps=\(showFPS ? 1 : 0)\n".write(toFile: configPath, atomically: true, encoding: .utf8)
    }
}

struct FGError: Error, CustomStringConvertible {
    let description: String
    init(_ s: String) { description = s }
}

// MARK: - Interpolação (VideoToolbox)

/// Tamanho da captura: o interpolador tem limite de pixels. 2x vai até 1080p; 3x e 4x pesam mais e ficam em 720p.
func captureSize(width w: CGFloat, height h: CGFloat, multiplier: Int) -> (Int, Int) {
    var maxPixels = 1920.0 * 1080, maxDim = 1920.0
    if #available(macOS 27.0, *) {
        if let p = VTLowLatencyFrameInterpolationConfiguration.maximumPixelCount(forSpatialScaleFactor: 1), p > 0 { maxPixels = Double(p) }
        if let d = VTLowLatencyFrameInterpolationConfiguration.maximumDimension(forSpatialScaleFactor: 1), d > 0 { maxDim = Double(d) }
    }
    if multiplier > 2 { maxPixels = min(maxPixels, 1280 * 720); maxDim = min(maxDim, 1280) }
    let s = min(1, (maxPixels / Double(w * h)).squareRoot(), maxDim / Double(max(w, h)))
    return (Int(Double(w) * s) & ~1, Int(Double(h) * s) & ~1)
}

final class Interpolator {
    let width: Int, height: Int
    let phases: [Float]
    private let processor = VTFrameProcessor()
    private var pool: CVPixelBufferPool?
    private var copyPool: CVPixelBufferPool?
    private var transfer: VTPixelTransferSession?

    init(width: Int, height: Int, multiplier: Int) throws {
        self.width = width
        self.height = height
        // 2x: o ponto do meio. 4x: os três pontos de "2 quadros" (0,25/0,5/0,75). 3x: um terço e dois terços.
        phases = multiplier == 2 ? [0.5] : multiplier == 3 ? [1.0 / 3, 2.0 / 3] : [0.25, 0.5, 0.75]
        guard let cfg = VTLowLatencyFrameInterpolationConfiguration(
            frameWidth: width, frameHeight: height, numberOfInterpolatedFrames: multiplier == 2 ? 1 : 2) else {
            throw FGError("o interpolador não aceita o tamanho \(width)x\(height)")
        }
        try processor.startSession(configuration: cfg)
        pool = Interpolator.makePool(cfg.destinationPixelBufferAttributes, width, height)
        copyPool = Interpolator.makePool(cfg.sourcePixelBufferAttributes, width, height)
        guard pool != nil, copyPool != nil else { throw FGError("sem memória para os quadros") }
        VTPixelTransferSessionCreate(allocator: nil, pixelTransferSessionOut: &transfer)
    }

    deinit { processor.endSession() }

    static func makePool(_ base: [String: Any], _ w: Int, _ h: Int) -> CVPixelBufferPool? {
        var a = base
        a[kCVPixelBufferPixelFormatTypeKey as String] = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        a[kCVPixelBufferWidthKey as String] = w
        a[kCVPixelBufferHeightKey as String] = h
        if a[kCVPixelBufferIOSurfacePropertiesKey as String] == nil { a[kCVPixelBufferIOSurfacePropertiesKey as String] = [String: Any]() }
        var pool: CVPixelBufferPool?
        CVPixelBufferPoolCreate(nil, [kCVPixelBufferPoolMinimumBufferCountKey as String: 8] as CFDictionary, a as CFDictionary, &pool)
        return pool
    }

    private func buffer(from pool: CVPixelBufferPool?) -> CVPixelBuffer? {
        guard let pool else { return nil }
        var pb: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pb)
        return pb
    }

    /// Cópia do quadro capturado no formato que o interpolador pede. O interpolador recusa os quadros do
    /// ScreenCaptureKit como vêm (erro -19740), e a cópia também devolve logo o quadro para a captura.
    func prepare(_ pb: CVPixelBuffer) -> CVPixelBuffer? {
        guard let transfer, let out = buffer(from: copyPool) else { return nil }
        guard VTPixelTransferSessionTransferImage(transfer, from: pb, to: out) == noErr else { return nil }
        CVBufferPropagateAttachments(pb, out)
        return out
    }

    /// Gera os quadros entre `prev` e `cur`. `done` recebe os quadros novos, em ordem, ou nil se falhou.
    func process(prev: CVPixelBuffer, prevTime: CMTime, cur: CVPixelBuffer, curTime: CMTime,
                 done: @escaping ([CVPixelBuffer]?) -> Void) {
        let span = CMTimeSubtract(curTime, prevTime)
        var outs: [CVPixelBuffer] = []
        var dests: [VTFrameProcessorFrame] = []
        for p in phases {
            guard let b = buffer(from: pool),
                  let f = VTFrameProcessorFrame(buffer: b, presentationTimeStamp: CMTimeAdd(prevTime, CMTimeMultiplyByFloat64(span, multiplier: Float64(p)))) else {
                done(nil); return
            }
            outs.append(b); dests.append(f)
        }
        guard let src = VTFrameProcessorFrame(buffer: cur, presentationTimeStamp: curTime),
              let old = VTFrameProcessorFrame(buffer: prev, presentationTimeStamp: prevTime),
              let params = VTLowLatencyFrameInterpolationParameters(sourceFrame: src, previousFrame: old,
                                                                    interpolationPhase: phases, destinationFrames: dests) else {
            done(nil); return
        }
        processor.process(parameters: params) { _, error in
            if let error {
                log("Falha ao gerar quadro: \(error.localizedDescription)")
                done(nil)
                return
            }
            for b in outs { CVBufferPropagateAttachments(cur, b) }
            done(outs)
        }
    }
}

// MARK: - Fila de quadros para a tela

/// Quadros prontos com a hora (CACurrentMediaTime) em que devem aparecer. Usada pela fila de trabalho e pela tela.
final class FrameQueue {
    private var lock = os_unfair_lock()
    private var items: [(buf: CVPixelBuffer, due: Double)] = []

    func push(_ batch: [(buf: CVPixelBuffer, due: Double)]) {
        os_unfair_lock_lock(&lock)
        items.append(contentsOf: batch)
        if items.count > 8 { skipped += items.count - 8; items.removeFirst(items.count - 8) }
        os_unfair_lock_unlock(&lock)
    }

    /// Próximo quadro para a atualização de tela que mostra em `t`: um por atualização e sempre em ordem,
    /// para o gerado e o real não caírem na mesma atualização (aí o gerado nunca apareceria).
    /// Atrasado (mais de dois vencidos, ex.: o jogo passou do dobro da taxa da tela), pula os mais velhos.
    func take(upTo t: Double) -> CVPixelBuffer? {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        let due = items.prefix { $0.due <= t }.count
        guard due > 0 else { return nil }
        if due > 2 { skipped += due - 2; items.removeFirst(due - 2) }
        return items.removeFirst().buf
    }

    func clear() {
        os_unfair_lock_lock(&lock); items.removeAll(); os_unfair_lock_unlock(&lock)
    }

    private(set) var skipped = 0   // quadros que não chegaram a aparecer (atraso)
}

// MARK: - Janela por cima do jogo

final class OverlayPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

final class Overlay: NSObject {
    let panel: OverlayPanel
    let video = CALayer()
    let label = CATextLayer()
    let queue: FrameQueue
    private var link: CADisplayLink?
    private var shown: CVPixelBuffer?     // segura o quadro que está na tela
    private(set) var presented = 0         // quadros mostrados (para o contador de FPS)

    init(frame: NSRect, level: Int, queue: FrameQueue, showFPS: Bool) {
        self.queue = queue
        panel = OverlayPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        super.init()
        panel.level = NSWindow.Level(rawValue: level)
        panel.ignoresMouseEvents = true
        // Uma janela opaca por cima faz o macOS considerar o jogo coberto, e o Metal do jogo cai para ~1 FPS.
        // Com 1% de transparência o jogo continua "visível" (e a mistura não aparece: embaixo está a mesma imagem).
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.alphaValue = 0.99
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        let view = NSView(frame: NSRect(origin: .zero, size: frame.size))
        view.wantsLayer = true
        view.layer?.backgroundColor = .clear
        video.frame = view.bounds
        video.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        video.contentsGravity = .resize
        video.backgroundColor = .clear
        video.actions = ["contents": NSNull(), "bounds": NSNull(), "position": NSNull()]
        view.layer?.addSublayer(video)
        label.fontSize = 13
        label.font = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .semibold)
        label.foregroundColor = NSColor.systemYellow.cgColor
        label.backgroundColor = NSColor.black.withAlphaComponent(0.55).cgColor
        label.cornerRadius = 4
        label.alignmentMode = .center
        label.contentsScale = NSScreen.main?.backingScaleFactor ?? 2
        label.isHidden = !showFPS
        label.actions = ["contents": NSNull(), "bounds": NSNull(), "position": NSNull(), "hidden": NSNull()]
        view.layer?.addSublayer(label)
        panel.contentView = view
        layoutLabel()
        link = view.displayLink(target: self, selector: #selector(tick(_:)))
        link?.add(to: .main, forMode: .common)
    }

    func layoutLabel() {
        guard let b = panel.contentView?.bounds else { return }
        label.frame = CGRect(x: 8, y: b.height - 30, width: 128, height: 20)
    }

    func setText(_ s: String) {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        label.string = s
        CATransaction.commit()
    }

    func setFrame(_ r: NSRect) {
        guard panel.frame != r else { return }
        panel.setFrame(r, display: false)
        layoutLabel()
    }

    func show(_ on: Bool) {
        if on && !panel.isVisible { panel.orderFrontRegardless() }
        if !on && panel.isVisible { panel.orderOut(nil) }
    }

    @objc func tick(_ link: CADisplayLink) {
        guard let buf = queue.take(upTo: link.targetTimestamp) else { return }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        video.contents = CVPixelBufferGetIOSurface(buf)?.takeUnretainedValue()
        CATransaction.commit()
        shown = buf
        presented += 1
    }

    func close() {
        link?.invalidate(); link = nil
        panel.orderOut(nil)
        panel.close()
        shown = nil
    }
}

// MARK: - Sessão: captura + interpolação + tela

final class Session: NSObject, SCStreamOutput, SCStreamDelegate {
    struct Frame { let buf: CVPixelBuffer; let pts: CMTime; let arrival: Double }

    let windowID: CGWindowID
    let pid: pid_t
    let appName: String
    let multiplier: Int
    let showFPS: Bool
    var onStop: ((String?) -> Void)?

    private let work = DispatchQueue(label: "winmac-fg.work", qos: .userInteractive)
    private let frames = FrameQueue()
    private var stream: SCStream?
    private var interp: Interpolator?
    private var overlay: Overlay?
    private var tracker: Timer?
    private var bounds = CGRect.zero
    private var stopped = false

    // Estado da fila de trabalho
    private var prev: Frame?
    private var pending: Frame?
    private var busy = false
    private var avgInterval = 1.0 / 30
    private var displayFPS = 60.0
    private var captured = 0, lastCaptured = 0, lastPresented = 0, lastStats = CACurrentMediaTime()
    private var procTime = 0.0

    init(windowID: CGWindowID, pid: pid_t, appName: String, settings: Settings) {
        self.windowID = windowID
        self.pid = pid
        self.appName = appName
        multiplier = settings.multiplier
        showFPS = settings.showFPS
    }

    static func windowInfo(_ id: CGWindowID) -> [String: Any]? {
        (CGWindowListCopyWindowInfo([.optionIncludingWindow], id) as? [[String: Any]])?.first
    }

    static func bounds(of info: [String: Any]) -> CGRect? {
        guard let d = info[kCGWindowBounds as String] as? NSDictionary else { return nil }
        return CGRect(dictionaryRepresentation: d)
    }

    /// Coordenadas do CGWindowList (origem no alto da tela principal) para as do AppKit (origem embaixo).
    static func cocoaRect(_ r: CGRect) -> NSRect {
        let h = NSScreen.screens.first?.frame.height ?? r.maxY
        return NSRect(x: r.minX, y: h - r.maxY, width: r.width, height: r.height)
    }

    func start(window: SCWindow) {
        guard let info = Session.windowInfo(windowID), let b = Session.bounds(of: info) else { finish("A janela sumiu."); return }
        bounds = b
        let layer = (info[kCGWindowLayer as String] as? Int) ?? 0
        let (cw, ch) = captureSize(width: b.width, height: b.height, multiplier: multiplier)
        log("Ligando em \(appName) (janela \(windowID), \(Int(b.width))x\(Int(b.height))): captura \(cw)x\(ch), \(multiplier)x")
        work.async {
            // Carregar o modelo do interpolador leva alguns segundos na primeira vez
            let t0 = CACurrentMediaTime()
            do {
                let interp = try Interpolator(width: cw, height: ch, multiplier: self.multiplier)
                log(String(format: "Interpolador pronto em %.1f s", CACurrentMediaTime() - t0))
                DispatchQueue.main.async { self.begin(window: window, interp: interp, layer: layer, cw: cw, ch: ch) }
            } catch {
                DispatchQueue.main.async { self.finish("Não deu para ligar o interpolador: \(error)") }
            }
        }
    }

    private func begin(window: SCWindow, interp: Interpolator, layer: Int, cw: Int, ch: Int) {
        guard !stopped else { return }
        self.interp = interp
        let overlay = Overlay(frame: Session.cocoaRect(bounds), level: layer + 1, queue: frames, showFPS: showFPS)
        let fps = Double((overlay.panel.screen ?? NSScreen.main)?.maximumFramesPerSecond ?? 60)
        work.async { self.displayFPS = fps > 0 ? fps : 60 }
        self.overlay = overlay
        overlay.setText("\(multiplier)x …")

        let cfg = SCStreamConfiguration()
        cfg.width = cw
        cfg.height = ch
        cfg.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        cfg.colorMatrix = CGDisplayStream.yCbCrMatrix_ITU_R_709_2
        // WINMAC_FG_CAPTURE_FPS (testes): captura menos quadros, como se o jogo rodasse mais devagar
        let capFPS = Int32(ProcessInfo.processInfo.environment["WINMAC_FG_CAPTURE_FPS"] ?? "") ?? 120
        cfg.minimumFrameInterval = CMTime(value: 1, timescale: max(1, capFPS))
        cfg.queueDepth = 8
        cfg.showsCursor = false
        cfg.capturesAudio = false
        cfg.scalesToFit = true
        cfg.ignoreShadowsSingleWindow = true
        cfg.shouldBeOpaque = true
        let stream = SCStream(filter: SCContentFilter(desktopIndependentWindow: window), configuration: cfg, delegate: self)
        do {
            try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: work)
        } catch {
            finish("Não deu para capturar a janela: \(error.localizedDescription)"); return
        }
        self.stream = stream
        stream.startCapture { error in
            guard let error else { return }
            DispatchQueue.main.async { self.finish("Não deu para capturar a janela: \(error.localizedDescription)") }
        }
        track()
        tracker = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in self?.track() }
    }

    /// Acompanha a janela do jogo: posição, tamanho e se o jogo está na frente.
    private func track() {
        guard !stopped, let overlay else { return }
        guard let info = Session.windowInfo(windowID), let b = Session.bounds(of: info) else { finish("O jogo fechou."); return }
        if abs(b.width - bounds.width) > 2 || abs(b.height - bounds.height) > 2 {
            finish("RESTART"); return   // mudou de tamanho: o agente religa com a captura no tamanho novo
        }
        bounds = b
        overlay.setFrame(Session.cocoaRect(b))
        let onScreen = (info[kCGWindowIsOnscreen as String] as? Bool) ?? false
        let front = NSWorkspace.shared.frontmostApplication?.processIdentifier == pid
        overlay.show(onScreen && front)

        let now = CACurrentMediaTime()
        if now - lastStats >= 0.5 {
            let dt = now - lastStats
            let inFPS = Double(captured - lastCaptured) / dt
            let outFPS = Double(overlay.presented - lastPresented) / dt
            lastCaptured = captured; lastPresented = overlay.presented; lastStats = now
            overlay.setText(String(format: "%.0f → %.0f FPS", inFPS, outFPS))
            if debug { log(String(format: "%.1f → %.1f FPS, interpolação %.1f ms, pulados %d", inFPS, outFPS, procTime * 1000, frames.skipped)) }
        }
    }

    // Quadro novo do ScreenCaptureKit (na fila de trabalho)
    func stream(_ stream: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sb.isValid,
              let atts = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let raw = atts.first?[.status] as? Int, SCFrameStatus(rawValue: raw) == .complete,
              let pb = CMSampleBufferGetImageBuffer(sb), !isRepeat(pb),
              let interp, let copy = interp.prepare(pb) else { return }
        captured += 1
        let f = Frame(buf: copy, pts: CMSampleBufferGetPresentationTimeStamp(sb), arrival: CACurrentMediaTime())
        if busy { pending = f } else { run(f) }   // ocupado: guarda só o mais recente
    }

    // A captura às vezes entrega o mesmo quadro de novo (a janela foi redesenhada sem mudar). Um quadro
    // repetido estragaria o ritmo: compara uma a cada 4 linhas do brilho (plano Y) com o quadro anterior.
    private var lastRows = Data(), rows = Data()
    private func isRepeat(_ pb: CVPixelBuffer) -> Bool {
        guard CVPixelBufferLockBaseAddress(pb, .readOnly) == kCVReturnSuccess else { return false }
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddressOfPlane(pb, 0) else { return false }
        let bpr = CVPixelBufferGetBytesPerRowOfPlane(pb, 0)
        let w = CVPixelBufferGetWidthOfPlane(pb, 0), h = CVPixelBufferGetHeightOfPlane(pb, 0)
        let n = h / 4
        if rows.count != n * w { rows = Data(count: n * w) }
        rows.withUnsafeMutableBytes { dst in
            for r in 0..<n { memcpy(dst.baseAddress! + r * w, base + r * 4 * bpr, w) }
        }
        let same = rows == lastRows
        swap(&rows, &lastRows)
        return same
    }

    private func run(_ f: Frame) {
        guard let interp, !stopped else { return }
        guard let p = prev else { prev = f; frames.push([(f.buf, f.arrival)]); return }
        let dt = f.arrival - p.arrival
        if dt > 0.004 && dt < 0.25 { avgInterval = avgInterval * 0.8 + dt * 0.2 }
        // Pausa longa (tela de carregamento, menu parado): não inventa quadros entre imagens distantes.
        // Jogo já perto da taxa da tela (ex.: 50 FPS numa tela de 60 Hz): não sobra lugar para quadro
        // gerado; passa direto, sem o atraso da interpolação.
        if dt >= 0.25 || CMTimeCompare(f.pts, p.pts) <= 0 || 1 / avgInterval > displayFPS * 0.75 {
            prev = f; frames.push([(f.buf, CACurrentMediaTime())]); return
        }
        busy = true
        let t0 = CACurrentMediaTime()
        interp.process(prev: p.buf, prevTime: p.pts, cur: f.buf, curTime: f.pts) { outs in
            self.work.async {
                self.busy = false
                let now = CACurrentMediaTime()
                if let outs {
                    self.procTime = self.procTime == 0 ? now - t0 : self.procTime * 0.9 + (now - t0) * 0.1
                    // Ritmo pela chegada do quadro real (mais estável que a hora em que o interpolador terminou):
                    // o intermediário sai um "tempo de interpolação" depois, e o real meio intervalo depois dele.
                    let base = max(now, f.arrival + self.procTime * 1.2)
                    let step = self.avgInterval / Double(outs.count + 1)
                    var batch = outs.enumerated().map { (buf: $0.element, due: base + Double($0.offset) * step) }
                    batch.append((buf: f.buf, due: base + Double(outs.count) * step))
                    self.frames.push(batch)
                } else {
                    self.frames.push([(f.buf, now)])
                }
                self.prev = f
                if let next = self.pending { self.pending = nil; self.run(next) }
            }
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        DispatchQueue.main.async { self.finish("A captura parou: \(error.localizedDescription)") }
    }

    func stop() { finish(nil) }

    private func finish(_ reason: String?) {
        guard !stopped else { return }
        stopped = true
        tracker?.invalidate(); tracker = nil
        stream?.stopCapture(completionHandler: nil); stream = nil
        overlay?.close(); overlay = nil
        frames.clear()
        work.async { self.prev = nil; self.pending = nil; self.interp = nil }
        if procTime > 0 { log(String(format: "Desligado (interpolação média: %.1f ms)", procTime * 1000)) }
        onStop?(reason)
    }
}

// MARK: - Agente na barra de menus

final class Agent: NSObject {
    static let shared = Agent()
    var settings = Settings.load()
    var session: Session?
    var status = "Desligado. No jogo, aperte ⌃⌥S."
    private var statusItem: NSStatusItem?
    private var hotKey: EventHotKeyRef?
    private var signals: [DispatchSourceSignal] = []

    func run(startNow: Bool, windowID: CGWindowID?) {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        setupStatusItem()
        registerHotKey()
        handleSignals()
        if !CGPreflightScreenCaptureAccess() {
            log("Falta a permissão de Gravação de Tela; pedindo ao macOS.")
            CGRequestScreenCaptureAccess()
        }
        if let windowID {
            DispatchQueue.main.async { self.start(windowID: windowID) }
        } else if startNow {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { self.startOnFrontWindow() }
        }
        log("Pronto. Control+Option+S liga e desliga no jogo da frente (\(settings.multiplier)x).")
        app.run()
    }

    // Control+Option+S, como o Control+Alt+S do Lossless Scaling. Atalho do Carbon: não precisa de permissão.
    private func registerHotKey() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
            DispatchQueue.main.async { Agent.shared.toggle() }
            return noErr
        }, 1, &spec, nil, nil)
        let id = EventHotKeyID(signature: OSType(0x574D_4647), id: 1)   // 'WMFG'
        let r = RegisterEventHotKey(UInt32(kVK_ANSI_S), UInt32(controlKey | optionKey), id, GetApplicationEventTarget(), 0, &hotKey)
        if r != noErr { log("Não consegui registrar o atalho Control+Option+S (erro \(r)). Use o menu.") }
    }

    private func handleSignals() {
        for sig in [SIGHUP, SIGTERM, SIGINT] {
            signal(sig, SIG_IGN)
            let src = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            src.setEventHandler {
                if sig == SIGHUP {
                    self.settings = Settings.load()
                    log("Ajustes relidos: \(self.settings.multiplier)x, FPS \(self.settings.showFPS ? "visível" : "escondido")")
                    if let s = self.session { self.restart(s) }
                    self.rebuildMenu()
                } else {
                    self.session?.stop()
                    exit(0)
                }
            }
            src.resume()
            signals.append(src)
        }
    }

    // MARK: Menu

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let img = NSImage(systemSymbolName: "rectangle.stack.fill", accessibilityDescription: "WinMac: quadros extras") {
            img.isTemplate = true
            item.button?.image = img
        } else {
            item.button?.title = "FG"
        }
        item.button?.toolTip = "WinMac: quadros extras (⌃⌥S)"
        statusItem = item
        rebuildMenu()
    }

    func rebuildMenu() {
        let menu = NSMenu()
        let head = NSMenuItem(title: status, action: nil, keyEquivalent: "")
        head.isEnabled = false
        menu.addItem(head)
        menu.addItem(.separator())
        let toggleItem = NSMenuItem(title: session == nil ? "Ligar no jogo da frente" : "Desligar",
                                    action: #selector(menuToggle), keyEquivalent: "s")
        toggleItem.keyEquivalentModifierMask = [.control, .option]
        toggleItem.target = self
        menu.addItem(toggleItem)
        menu.addItem(.separator())
        for m in 2...4 {
            let it = NSMenuItem(title: "\(m)x" + (m == 2 ? " (recomendado)" : " (captura em 720p)"),
                                action: #selector(setMultiplier(_:)), keyEquivalent: "")
            it.tag = m
            it.target = self
            it.state = settings.multiplier == m ? .on : .off
            menu.addItem(it)
        }
        menu.addItem(.separator())
        let fps = NSMenuItem(title: "Mostrar FPS", action: #selector(toggleFPS), keyEquivalent: "")
        fps.target = self
        fps.state = settings.showFPS ? .on : .off
        menu.addItem(fps)
        if !CGPreflightScreenCaptureAccess() {
            let perm = NSMenuItem(title: "Permitir Gravação de Tela…", action: #selector(openPrivacy), keyEquivalent: "")
            perm.target = self
            menu.addItem(perm)
        }
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Sair", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
        statusItem?.menu = menu
    }

    @objc private func menuToggle() { toggle() }

    @objc private func setMultiplier(_ sender: NSMenuItem) {
        settings.multiplier = sender.tag
        settings.save()
        if let s = session { restart(s) }
        rebuildMenu()
    }

    @objc private func toggleFPS() {
        settings.showFPS.toggle()
        settings.save()
        if let s = session { restart(s) }
        rebuildMenu()
    }

    @objc private func openPrivacy() {
        CGRequestScreenCaptureAccess()
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
    }

    @objc private func quit() {
        session?.stop()
        exit(0)
    }

    private func setStatus(_ s: String) {
        status = s
        rebuildMenu()
    }

    // MARK: Ligar e desligar

    func toggle() {
        if let s = session { s.stop() } else { startOnFrontWindow() }
    }

    /// Maior janela do app da frente (o jogo). As janelas do Wine pertencem ao processo do próprio .exe.
    func startOnFrontWindow() {
        guard let app = NSWorkspace.shared.frontmostApplication else { return }
        let pid = app.processIdentifier
        guard pid != getpid() else { return }
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        let best = list.filter {
            ($0[kCGWindowOwnerPID as String] as? pid_t) == pid &&
            (0..<1000).contains(($0[kCGWindowLayer as String] as? Int) ?? -1)
        }.compactMap { w -> (CGWindowID, CGFloat)? in
            guard let id = w[kCGWindowNumber as String] as? CGWindowID, let b = Session.bounds(of: w),
                  b.width >= 200, b.height >= 150 else { return nil }
            return (id, b.width * b.height)
        }.max { $0.1 < $1.1 }
        guard let best else {
            setStatus("Não achei a janela de \(app.localizedName ?? "app da frente").")
            NSSound.beep()
            return
        }
        start(windowID: best.0)
    }

    func start(windowID: CGWindowID) {
        guard session == nil else { return }
        guard CGPreflightScreenCaptureAccess() else {
            setStatus("Falta permitir a Gravação de Tela.")
            log("Sem permissão de Gravação de Tela. Permita em Ajustes do Sistema > Privacidade e Segurança > Gravação de Tela.")
            CGRequestScreenCaptureAccess()
            NSSound.beep()
            return
        }
        guard let info = Session.windowInfo(windowID), let pid = info[kCGWindowOwnerPID as String] as? pid_t else {
            setStatus("Janela \(windowID) não encontrada."); return
        }
        // Os processos do Wine se chamam todos "wine": o título da janela diz qual é o jogo
        let title = (info[kCGWindowName as String] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let name = title ?? NSRunningApplication(processIdentifier: pid)?.localizedName
            ?? (info[kCGWindowOwnerName as String] as? String) ?? "jogo"
        let s = Session(windowID: windowID, pid: pid, appName: name, settings: settings)
        session = s
        s.onStop = { [weak self, weak s] reason in
            guard let self, let s, self.session === s else { return }
            self.session = nil
            if reason == "RESTART" {
                log("A janela mudou de tamanho; religando.")
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.start(windowID: windowID) }
                return
            }
            if let reason { log(reason) }
            self.setStatus(reason.map { "Desligado: \($0)" } ?? "Desligado. No jogo, aperte ⌃⌥S.")
        }
        setStatus("Ligando em \(name)…")
        SCShareableContent.getExcludingDesktopWindows(true, onScreenWindowsOnly: false) { content, error in
            DispatchQueue.main.async {
                guard self.session === s else { return }
                guard let w = content?.windows.first(where: { $0.windowID == windowID }) else {
                    self.session = nil
                    let why = error?.localizedDescription ?? "a janela não apareceu para a captura"
                    log("Não deu para capturar: \(why)")
                    self.setStatus("Não deu para capturar: \(why)")
                    return
                }
                s.start(window: w)
                self.setStatus("Ligado em \(name) (\(self.settings.multiplier)x). ⌃⌥S desliga.")
            }
        }
    }

    private func restart(_ s: Session) {
        let id = s.windowID
        s.onStop = nil
        s.stop()
        session = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { self.start(windowID: id) }
    }
}

// MARK: - Início

guard #available(macOS 26.0, *), VTLowLatencyFrameInterpolationConfiguration.isSupported else {
    print("A geração de quadros precisa do macOS 26 ou mais novo num Mac com chip Apple.")
    exit(2)
}

// Uma cópia só: a segunda sai na hora
let lockFD = open("\(home)/winmac/.framegen.lock", O_CREAT | O_RDWR, 0o644)
if lockFD < 0 || flock(lockFD, LOCK_EX | LOCK_NB) != 0 {
    print("O winmac-fg já está rodando (ícone na barra de menus).")
    exit(0)
}

var args = Array(CommandLine.arguments.dropFirst())
var startNow = false
var windowArg: CGWindowID?
while !args.isEmpty {
    let a = args.removeFirst()
    switch a {
    case "--now": startNow = true
    case "--window": windowArg = args.isEmpty ? nil : CGWindowID(args.removeFirst())
    default: print("Opção desconhecida: \(a)"); exit(1)
    }
}
Agent.shared.run(startNow: startNow, windowID: windowArg)
