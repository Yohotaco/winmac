// WinMac Quadros: gera quadros extras para os jogos do WinMac, no estilo do Lossless Scaling do Windows.
//
// O Lossless Scaling não roda no Wine: ele captura a tela com funções que só o Windows tem (DXGI Desktop
// Duplication / Windows Graphics Capture) e fecha ao abrir. Aqui o próprio macOS faz o mesmo trabalho:
//  1. o ScreenCaptureKit captura só a janela do jogo, mesmo que outra janela esteja por cima dela;
//  2. o interpolador de baixa latência do VideoToolbox (macOS 26 ou mais novo) cria os quadros entre dois
//     quadros reais. Ele roda no Neural Engine, então não disputa a GPU com o jogo;
//  3. uma janela que deixa o mouse passar, por cima do jogo, mostra os quadros reais e os gerados
//     alternados, no ritmo da tela. O mouse e o teclado continuam indo para o jogo, que fica embaixo.
//
// É um app com janela (WinMac.app/Contents/Helpers/WinMac Quadros.app, montado pelo app/build.sh): mostra se
// está ligado e o FPS. "Ligar no jogo" acha sozinho a janela do jogo do Windows; Control+Option+S (o atalho
// do Lossless Scaling) liga e desliga no jogo da frente. Por ser um app próprio, a permissão de Gravação de
// Tela fica com ele, não importa quem o abriu (WinMac, Terminal ou a Steam pelo embrulho do Lossless Scaling).
// Testes: --now faz o mesmo que o botão "Ligar no jogo"; --window <id> liga numa janela específica.
// Ajustes em ~/winmac/framegen.conf (multiplier=2|3|4, fps=0|1). SIGHUP relê o arquivo.

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
    // Limite do interpolador (o macOS 27 informa 1920 de lado e 1920×1080 de área; fixo para compilar com o SDK 26)
    var maxPixels = 1920.0 * 1080, maxDim = 1920.0
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
    let toast = CATextLayer()
    private var toastTimer: Timer?
    var pendingToast: String?   // aviso para quando o jogo aparecer (ele pode estar escondido ao ligar)
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
        toast.fontSize = 18
        toast.font = NSFont.systemFont(ofSize: 18, weight: .semibold)
        toast.foregroundColor = NSColor.white.cgColor
        toast.backgroundColor = NSColor.black.withAlphaComponent(0.7).cgColor
        toast.cornerRadius = 10
        toast.alignmentMode = .center
        toast.contentsScale = label.contentsScale
        toast.isHidden = true
        toast.actions = label.actions
        view.layer?.addSublayer(toast)
        panel.contentView = view
        layoutLabel()
        link = view.displayLink(target: self, selector: #selector(tick(_:)))
        link?.add(to: .main, forMode: .common)
    }

    static func textWidth(_ s: String, _ font: NSFont) -> CGFloat {
        ceil(NSAttributedString(string: s, attributes: [.font: font]).size().width)
    }

    func layoutLabel() {
        guard let b = panel.contentView?.bounds else { return }
        let text = label.string as? String ?? ""
        label.frame = CGRect(x: 8, y: b.height - 30, width: Overlay.textWidth(text, NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .semibold)) + 16, height: 20)
        let t = toast.string as? String ?? ""
        let w = Overlay.textWidth(t, NSFont.systemFont(ofSize: 18, weight: .semibold)) + 32
        toast.frame = CGRect(x: (b.width - w) / 2, y: b.height - 90, width: w, height: 32)
    }

    func setText(_ s: String) {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        label.string = s
        layoutLabel()
        CATransaction.commit()
    }

    /// Aviso grande no alto do jogo por alguns segundos (ex.: "Quadros extras ligados").
    func showToast(_ s: String) {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        toast.string = s
        toast.isHidden = false
        layoutLabel()
        CATransaction.commit()
        toastTimer?.invalidate()
        toastTimer = Timer.scheduledTimer(withTimeInterval: 3.5, repeats: false) { [weak self] _ in
            CATransaction.begin(); CATransaction.setDisableActions(true)
            self?.toast.isHidden = true
            CATransaction.commit()
        }
    }

    func setFrame(_ r: NSRect) {
        guard panel.frame != r else { return }
        panel.setFrame(r, display: false)
        layoutLabel()
    }

    func show(_ on: Bool) {
        if on && !panel.isVisible {
            panel.orderFrontRegardless()
            if let t = pendingToast { pendingToast = nil; showToast(t) }
        }
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
        toastTimer?.invalidate(); toastTimer = nil
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
    var onStarted: (() -> Void)?
    /// A cada meio segundo: FPS do jogo, FPS na tela e se os quadros estão passando direto (jogo já rápido)
    var onStats: ((Double, Double, Bool) -> Void)?
    private(set) var gameVisible = false
    private(set) var displayRate = 60.0

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
    private var passing = false   // jogo perto da taxa da tela: quadros passam direto

    init(windowID: CGWindowID, pid: pid_t, appName: String, settings: Settings) {
        self.windowID = windowID
        self.pid = pid
        self.appName = appName
        multiplier = settings.multiplier
        showFPS = settings.showFPS
    }

    /// Dados da janela, mesmo escondida (o jogo em tela cheia some quando outro app vem para a frente).
    /// O CGWindowListCopyWindowInfo(.optionIncludingWindow) não devolve janelas fora da tela.
    static func windowInfo(_ id: CGWindowID) -> [String: Any]? {
        var value = UnsafeRawPointer(bitPattern: UInt(id))
        guard let arr = CFArrayCreate(nil, &value, 1, nil),
              let list = CGWindowListCreateDescriptionFromArray(arr) as? [[String: Any]] else { return nil }
        return list.first
    }

    /// Maior janela de um processo (o jogo pode recriar a janela ao trocar o modo de tela)
    static func mainWindow(of pid: pid_t) -> CGWindowID? {
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        return list.filter {
            ($0[kCGWindowOwnerPID as String] as? pid_t) == pid &&
            (0..<1000).contains(($0[kCGWindowLayer as String] as? Int) ?? -1)
        }.compactMap { w -> (CGWindowID, CGFloat)? in
            guard let id = w[kCGWindowNumber as String] as? CGWindowID, let b = bounds(of: w),
                  b.width >= 400, b.height >= 300 else { return nil }
            return (id, b.width * b.height)
        }.max { $0.1 < $1.1 }?.0
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
        displayRate = fps > 0 ? fps : 60
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
            DispatchQueue.main.async {
                if let error { self.finish("Não deu para capturar a janela: \(error.localizedDescription)") }
                else if !self.stopped { self.onStarted?() }
            }
        }
        track()
        tracker = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in self?.track() }
    }

    /// Acompanha a janela do jogo: posição, tamanho e se o jogo está na frente.
    private func track() {
        guard !stopped, let overlay else { return }
        guard let info = Session.windowInfo(windowID), let b = Session.bounds(of: info) else {
            // A janela sumiu: o jogo fechou, ou recriou a janela (o agente espera ela voltar)
            finish(kill(pid, 0) == 0 ? "LOST" : "O jogo fechou."); return
        }
        if abs(b.width - bounds.width) > 2 || abs(b.height - bounds.height) > 2 {
            finish("RESTART"); return   // mudou de tamanho: o agente religa com a captura no tamanho novo
        }
        bounds = b
        overlay.setFrame(Session.cocoaRect(b))
        let onScreen = (info[kCGWindowIsOnscreen as String] as? Bool) ?? false
        let front = NSWorkspace.shared.frontmostApplication?.processIdentifier == pid
        gameVisible = onScreen && front
        overlay.show(gameVisible)

        let now = CACurrentMediaTime()
        if now - lastStats >= 0.5 {
            let dt = now - lastStats
            let inFPS = Double(captured - lastCaptured) / dt
            let outFPS = Double(overlay.presented - lastPresented) / dt
            lastCaptured = captured; lastPresented = overlay.presented; lastStats = now
            overlay.setText(inFPS < 1 ? "jogo parado" : passing ? String(format: "%.0f FPS · jogo já rápido", inFPS)
                                                         : String(format: "%.0f → %.0f FPS", inFPS, outFPS))
            onStats?(inFPS, outFPS, passing)
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
        let fast = 1 / avgInterval > displayFPS * 0.75
        if dt < 0.25 { passing = fast }
        if dt >= 0.25 || CMTimeCompare(f.pts, p.pts) <= 0 || fast {
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

    func setFPSVisible(_ on: Bool) {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        overlay?.label.isHidden = !on
        CATransaction.commit()
    }

    func toast(_ s: String) {
        guard let overlay else { return }
        if overlay.panel.isVisible { overlay.showToast(s) } else { overlay.pendingToast = s }
    }

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

// MARK: - Achar o jogo

/// Argumentos de um processo. No Wine, o primeiro é o caminho do .exe do Windows ("C:\...\jogo.exe").
func processArgs(_ pid: pid_t) -> [String] {
    var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
    var size = 0
    guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 4 else { return [] }
    var buf = [UInt8](repeating: 0, count: size)
    guard sysctl(&mib, 3, &buf, &size, nil, 0) == 0, size > 4 else { return [] }
    // argc, caminho do executável, zeros, depois os argumentos separados por \0 (e o ambiente, ignorado)
    var argc: Int32 = 0
    memcpy(&argc, buf, 4)
    var i = 4
    while i < size && buf[i] != 0 { i += 1 }
    while i < size && buf[i] == 0 { i += 1 }
    var args: [String] = []
    while args.count < Int(argc) && i < size {
        let start = i
        while i < size && buf[i] != 0 { i += 1 }
        args.append(String(decoding: buf[start..<i], as: UTF8.self))
        i += 1
    }
    return args
}

/// Programas do Windows que não são jogos (a Steam, launchers, o próprio Wine)
let notGames = ["\\steam.exe", "steamwebhelper", "steamservice", "wallpaper", "winmac-progman", "explorer.exe",
                "losslessscaling", "launcher", "eadesktop", "crashhandler", "services.exe", "winedevice",
                "plugplay", "rpcss", "conhost", "start.exe", "cmd.exe", "winedbg"]

/// Janela de jogo do Windows mais à frente: janela grande de um processo do Wine que não é a Steam nem launcher.
/// Inclui as escondidas: o jogo em tela cheia some quando a janela do WinMac Quadros vem para a frente.
func findWineGameWindow() -> CGWindowID? {
    let list = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
    for w in list {   // as da tela primeiro, da frente para trás; depois as escondidas
        guard let pid = w[kCGWindowOwnerPID as String] as? pid_t, pid != getpid(),
              (0..<1000).contains((w[kCGWindowLayer as String] as? Int) ?? -1),
              let id = w[kCGWindowNumber as String] as? CGWindowID, let b = Session.bounds(of: w),
              b.width >= 400, b.height >= 300 else { continue }
        let cmd = processArgs(pid).joined(separator: " ").lowercased()
        guard cmd.contains(".exe"), !notGames.contains(where: { cmd.contains($0) }) else { continue }
        return id
    }
    return nil
}

/// Maior janela do app da frente (jogos do Mac ou qualquer janela).
func frontAppWindow() -> CGWindowID? {
    guard let app = NSWorkspace.shared.frontmostApplication, app.processIdentifier != getpid() else { return nil }
    let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
    return list.filter {
        ($0[kCGWindowOwnerPID as String] as? pid_t) == app.processIdentifier &&
        (0..<1000).contains(($0[kCGWindowLayer as String] as? Int) ?? -1)
    }.compactMap { w -> (CGWindowID, CGFloat)? in
        guard let id = w[kCGWindowNumber as String] as? CGWindowID, let b = Session.bounds(of: w),
              b.width >= 200, b.height >= 150 else { return nil }
        return (id, b.width * b.height)
    }.max { $0.1 < $1.1 }?.0
}

// MARK: - Janela do WinMac Quadros

final class Controller: NSObject, NSApplicationDelegate, NSWindowDelegate {
    static let shared = Controller()

    enum UIState { case off(String?), waiting(Int), starting(String), on(String), failed(String) }

    var settings = Settings.load()
    var startNow = false
    var startWindow: CGWindowID?
    private(set) var session: Session?
    private var state = UIState.off(nil)
    private var window: NSWindow!
    private let stateLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(wrappingLabelWithString: "")
    private let mainButton = NSButton(title: "", target: nil, action: nil)
    private let multControl = NSSegmentedControl(labels: ["2x", "3x", "4x"], trackingMode: .selectOne, target: nil, action: nil)
    private let fpsCheck = NSButton(checkboxWithTitle: "Mostrar o FPS no canto do jogo", target: nil, action: nil)
    private let permBox = NSStackView()
    private var hotKey: EventHotKeyRef?
    private var signals: [DispatchSourceSignal] = []
    private var countdown: Timer?
    private var countdownLeft = 0
    private var waitTimer: Timer?   // espera a janela do jogo voltar

    func applicationDidFinishLaunching(_ n: Notification) {
        buildMenu()
        buildWindow()
        registerHotKey()
        handleSignals()
        render(.off(nil))
        showWindow()
        log("Pronto. Control+Option+S liga e desliga no jogo da frente (\(settings.multiplier)x).")
        if let id = startWindow {
            start(windowID: id, activateGame: false)
        } else if startNow {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.mainAction() }
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        showWindow()
        return true
    }

    // Fechar a janela só esconde: o atalho continua valendo. Para sair: Command+Q.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        sender.orderOut(nil)
        return false
    }

    func applicationWillTerminate(_ n: Notification) { session?.stop() }

    // MARK: Interface

    private func buildMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        main.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Esconder o WinMac Quadros", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Sair do WinMac Quadros", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        let winItem = NSMenuItem()
        main.addItem(winItem)
        let winMenu = NSMenu(title: "Janela")
        winMenu.addItem(withTitle: "Fechar", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        winItem.submenu = winMenu
        NSApp.mainMenu = main
    }

    private func label(_ s: String, size: CGFloat, weight: NSFont.Weight = .regular, secondary: Bool = false) -> NSTextField {
        let l = NSTextField(wrappingLabelWithString: s)
        l.font = .systemFont(ofSize: size, weight: weight)
        if secondary { l.textColor = .secondaryLabelColor }
        l.preferredMaxLayoutWidth = 400
        return l
    }

    private func buildWindow() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 440, height: 360),
                          styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "WinMac Quadros"
        window.isReleasedWhenClosed = false
        window.delegate = self

        let title = label("Quadros extras", size: 22, weight: .bold)
        let subtitle = label("Mais FPS nos jogos, como o Lossless Scaling: o Mac cria um quadro entre cada dois quadros do jogo.", size: 13, secondary: true)

        stateLabel.font = .systemFont(ofSize: 17, weight: .semibold)
        detailLabel.font = .systemFont(ofSize: 13)
        detailLabel.preferredMaxLayoutWidth = 372
        let statusBox = NSStackView(views: [stateLabel, detailLabel])
        statusBox.orientation = .vertical
        statusBox.alignment = .leading
        statusBox.spacing = 4
        statusBox.edgeInsets = NSEdgeInsets(top: 12, left: 14, bottom: 12, right: 14)
        statusBox.wantsLayer = true
        statusBox.layer?.cornerRadius = 10
        statusBox.layer?.backgroundColor = NSColor.gray.withAlphaComponent(0.15).cgColor
        statusBox.widthAnchor.constraint(equalToConstant: 400).isActive = true

        mainButton.target = self
        mainButton.action = #selector(mainAction)
        mainButton.bezelStyle = .push
        mainButton.controlSize = .large
        mainButton.keyEquivalent = "\r"

        multControl.target = self
        multControl.action = #selector(multChanged)
        multControl.selectedSegment = settings.multiplier - 2
        let multRow = NSStackView(views: [label("Multiplicador:", size: 13), multControl,
                                          label("2x leva 30 FPS a 60", size: 12, secondary: true)])
        multRow.spacing = 8

        fpsCheck.target = self
        fpsCheck.action = #selector(fpsChanged)
        fpsCheck.state = settings.showFPS ? .on : .off

        let permText = label("Para ver a janela do jogo, o macOS precisa da permissão de Gravação de Tela para o WinMac Quadros. Clique em Abrir os Ajustes, ligue o WinMac Quadros na lista e depois clique em Reabrir.", size: 12)
        permText.textColor = .systemOrange
        let openPrefs = NSButton(title: "Abrir os Ajustes", target: self, action: #selector(openPrivacy))
        let relaunchBtn = NSButton(title: "Reabrir", target: self, action: #selector(relaunch))
        let permButtons = NSStackView(views: [openPrefs, relaunchBtn])
        permBox.orientation = .vertical
        permBox.alignment = .leading
        permBox.spacing = 6
        permBox.addArrangedSubview(permText)
        permBox.addArrangedSubview(permButtons)

        let hint = label("Dentro do jogo: Control+Option+S liga e desliga.", size: 12, secondary: true)

        let stack = NSStackView(views: [title, subtitle, statusBox, mainButton, multRow, fpsCheck, permBox, hint])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.setCustomSpacing(4, after: title)
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        window.contentView = stack
    }

    func showWindow() {
        if !window.isVisible { window.center() }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    private func fitWindow() {
        guard let v = window.contentView else { return }
        v.layoutSubtreeIfNeeded()
        let size = v.fittingSize
        var f = window.frame
        let h = window.frameRect(forContentRect: NSRect(origin: .zero, size: size)).height
        f.origin.y += f.height - h
        f.size.height = h
        window.setFrame(f, display: true)
    }

    func render(_ s: UIState) {
        state = s
        switch s {
        case .off(let msg):
            stateLabel.stringValue = "Desligado"
            stateLabel.textColor = .secondaryLabelColor
            detailLabel.stringValue = msg ?? "Abra o jogo e clique em Ligar no jogo. Ou, dentro do jogo, aperte Control+Option+S."
            mainButton.title = "Ligar no jogo"
        case .waiting(let n):
            stateLabel.stringValue = "Clique na janela do jogo… \(n)"
            stateLabel.textColor = .labelColor
            detailLabel.stringValue = "Não achei um jogo do Windows aberto. Clique na janela do jogo: os quadros extras ligam nela em \(n) s."
            mainButton.title = "Cancelar"
        case .starting(let name):
            stateLabel.stringValue = "Ligando em \(name)…"
            stateLabel.textColor = .labelColor
            detailLabel.stringValue = "Preparando o gerador de quadros (leva alguns segundos na primeira vez)."
            mainButton.title = "Desligar"
        case .on(let name):
            stateLabel.stringValue = "Ligado em \(name)"
            stateLabel.textColor = .systemGreen
            detailLabel.stringValue = "Esperando o primeiro quadro do jogo…"
            mainButton.title = "Desligar"
        case .failed(let msg):
            stateLabel.stringValue = "Não ligou"
            stateLabel.textColor = .systemRed
            detailLabel.stringValue = msg
            mainButton.title = "Tentar de novo"
        }
        permBox.isHidden = CGPreflightScreenCaptureAccess()
        fitWindow()
    }

    private func showStats(inFPS: Double, outFPS: Double, passing: Bool, refresh: Double, visible: Bool) {
        guard case .on = state else { return }
        let text: String
        if !visible {
            text = "Volte para o jogo (clique nele no Dock ou use Command+Tab): os quadros extras aparecem quando ele estiver na frente."
        } else if inFPS < 1 {
            text = "O jogo está parado (nada mudou na tela). Os quadros extras voltam quando ele se mexer."
        } else if passing {
            text = String(format: "O jogo já roda a %.0f FPS, perto do máximo da tela (%.0f Hz): não sobra lugar para quadro extra, então os quadros passam direto. Funciona em jogos abaixo de %.0f FPS.", inFPS, refresh, refresh * 0.75)
        } else {
            text = String(format: "Jogo a %.0f FPS → %.0f FPS na tela. Funcionando: um quadro gerado entre cada dois do jogo.", inFPS, outFPS)
        }
        if detailLabel.stringValue != text {
            detailLabel.stringValue = text
            fitWindow()
        }
    }

    // MARK: Ações

    @objc func mainAction() {
        if countdown != nil || waitTimer != nil { cancelCountdown(); render(.off(nil)); return }
        if let s = session { s.stop(); return }
        guard ensurePermission() else { return }
        if let id = findWineGameWindow() { start(windowID: id, activateGame: true); return }
        // Sem jogo do Windows aberto: liga na janela em que a pessoa clicar nos próximos 5 s (vale para jogos do Mac)
        countdownLeft = 5
        render(.waiting(countdownLeft))
        countdown = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] t in
            guard let self else { t.invalidate(); return }
            self.countdownLeft -= 1
            if self.countdownLeft > 0 { self.render(.waiting(self.countdownLeft)); return }
            self.cancelCountdown()
            if !self.startFront() {
                self.render(.off("Não achei a janela do jogo. Abra o jogo e clique em Ligar no jogo de novo, ou aperte Control+Option+S dentro dele."))
            }
        }
    }

    private func cancelCountdown() {
        countdown?.invalidate()
        countdown = nil
        waitTimer?.invalidate()
        waitTimer = nil
    }

    /// O jogo recriou a janela (ex.: trocou de modo de tela): religa na janela nova quando ela aparecer
    private func waitForWindow(pid: pid_t, name: String) {
        render(.starting(name))
        detailLabel.stringValue = "A janela do jogo sumiu (o jogo trocou de modo de tela?). Esperando ela voltar…"
        waitTimer?.invalidate()
        waitTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] t in
            guard let self else { t.invalidate(); return }
            if kill(pid, 0) != 0 { self.cancelCountdown(); self.render(.off("O jogo fechou.")); return }
            guard let id = Session.mainWindow(of: pid) else { return }
            self.cancelCountdown()
            log("Janela nova do jogo: \(id); religando.")
            self.start(windowID: id, activateGame: false)
        }
    }

    @objc private func multChanged() {
        settings.multiplier = multControl.selectedSegment + 2
        settings.save()
        if let s = session { restart(s) }
    }

    @objc private func fpsChanged() {
        settings.showFPS = fpsCheck.state == .on
        settings.save()
        session?.setFPSVisible(settings.showFPS)
    }

    @objc private func openPrivacy() {
        CGRequestScreenCaptureAccess()
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
    }

    /// A permissão nova só vale depois de reabrir o app
    @objc private func relaunch() {
        session?.stop()
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "sleep 1; open \"$0\"", Bundle.main.bundlePath]
        try? p.run()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { exit(0) }
    }

    private func ensurePermission() -> Bool {
        if CGPreflightScreenCaptureAccess() { return true }
        log("Sem permissão de Gravação de Tela.")
        CGRequestScreenCaptureAccess()
        render(.failed("Falta a permissão de Gravação de Tela (veja abaixo)."))
        showWindow()
        return false
    }

    // Control+Option+S, como o Control+Alt+S do Lossless Scaling. Atalho do Carbon: não precisa de permissão.
    private func registerHotKey() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
            DispatchQueue.main.async { Controller.shared.hotKeyPressed() }
            return noErr
        }, 1, &spec, nil, nil)
        let id = EventHotKeyID(signature: OSType(0x574D_4647), id: 1)   // 'WMFG'
        let r = RegisterEventHotKey(UInt32(kVK_ANSI_S), UInt32(controlKey | optionKey), id, GetApplicationEventTarget(), 0, &hotKey)
        if r != noErr { log("Não consegui registrar o atalho Control+Option+S (erro \(r)).") }
    }

    func hotKeyPressed() {
        if waitTimer != nil { cancelCountdown(); render(.off(nil)); return }
        cancelCountdown()
        if let s = session { s.stop(); return }
        guard ensurePermission() else { return }
        if !startFront() {
            render(.off("Não achei a janela do jogo da frente."))
            showWindow()
        }
    }

    /// Liga na janela do app da frente; se a frente é esta janela, no jogo do Windows aberto.
    @discardableResult
    func startFront() -> Bool {
        let front = NSWorkspace.shared.frontmostApplication?.processIdentifier == getpid()
        guard let id = front ? findWineGameWindow() : frontAppWindow() else { return false }
        start(windowID: id, activateGame: front)
        return true
    }

    private func handleSignals() {
        for sig in [SIGHUP, SIGTERM, SIGINT] {
            signal(sig, SIG_IGN)
            let src = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            src.setEventHandler {
                if sig == SIGHUP {
                    let old = self.settings
                    self.settings = Settings.load()
                    self.multControl.selectedSegment = self.settings.multiplier - 2
                    self.fpsCheck.state = self.settings.showFPS ? .on : .off
                    self.session?.setFPSVisible(self.settings.showFPS)
                    log("Ajustes relidos: \(self.settings.multiplier)x, FPS \(self.settings.showFPS ? "visível" : "escondido")")
                    if let s = self.session, old.multiplier != self.settings.multiplier { self.restart(s) }
                } else {
                    self.session?.stop()
                    exit(0)
                }
            }
            src.resume()
            signals.append(src)
        }
    }

    // MARK: Ligar e desligar

    func start(windowID: CGWindowID, activateGame: Bool) {
        guard session == nil else { return }
        guard let info = Session.windowInfo(windowID), let pid = info[kCGWindowOwnerPID as String] as? pid_t else {
            render(.failed("A janela do jogo sumiu.")); return
        }
        // Os processos do Wine se chamam todos "wine": o título da janela diz qual é o jogo
        let title = (info[kCGWindowName as String] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let name = title ?? NSRunningApplication(processIdentifier: pid)?.localizedName
            ?? (info[kCGWindowOwnerName as String] as? String) ?? "jogo"
        let s = Session(windowID: windowID, pid: pid, appName: name, settings: settings)
        session = s
        let mult = settings.multiplier
        s.onStarted = { [weak self, weak s] in
            guard let self, let s, self.session === s else { return }
            self.render(.on(name))
            s.toast("Quadros extras ligados (\(mult)x) · Control+Option+S desliga")
        }
        s.onStats = { [weak self, weak s] i, o, p in
            guard let self, let s, self.session === s else { return }
            self.showStats(inFPS: i, outFPS: o, passing: p, refresh: s.displayRate, visible: s.gameVisible)
        }
        s.onStop = { [weak self, weak s] reason in
            guard let self, let s, self.session === s else { return }
            self.session = nil
            if reason == "RESTART" {
                log("A janela mudou de tamanho; religando.")
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.start(windowID: windowID, activateGame: false) }
                return
            }
            guard let reason else { self.render(.off(nil)); return }
            if reason == "LOST" { log("A janela do jogo sumiu; esperando ela voltar."); self.waitForWindow(pid: pid, name: name); return }
            log(reason)
            if reason == "O jogo fechou." { self.render(.off("O jogo fechou.")) }
            else { self.render(.failed(reason)); self.showWindow() }
        }
        render(.starting(name))
        if activateGame { NSRunningApplication(processIdentifier: pid)?.activate() }
        SCShareableContent.getExcludingDesktopWindows(true, onScreenWindowsOnly: false) { content, error in
            DispatchQueue.main.async {
                guard self.session === s else { return }
                guard let w = content?.windows.first(where: { $0.windowID == windowID }) else {
                    self.session = nil
                    let why = error?.localizedDescription ?? "a janela não apareceu para a captura"
                    log("Não deu para capturar: \(why)")
                    self.render(.failed("Não deu para capturar a janela do jogo: \(why)"))
                    self.showWindow()
                    return
                }
                s.start(window: w)
            }
        }
    }

    private func restart(_ s: Session) {
        let id = s.windowID
        s.onStop = nil
        s.stop()
        session = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { self.start(windowID: id, activateGame: false) }
    }
}

// MARK: - Início

guard #available(macOS 26.0, *), VTLowLatencyFrameInterpolationConfiguration.isSupported else {
    print("A geração de quadros precisa do macOS 26 ou mais novo num Mac com chip Apple.")
    exit(2)
}

// Uma cópia só (o "open" já garante isso para o app; aqui vale também para quem roda o binário direto)
try? FileManager.default.createDirectory(atPath: "\(home)/winmac", withIntermediateDirectories: true)
let lockFD = open("\(home)/winmac/.quadros.lock", O_CREAT | O_RDWR, 0o644)
if lockFD < 0 || flock(lockFD, LOCK_EX | LOCK_NB) != 0 {
    print("O WinMac Quadros já está aberto.")
    exit(0)
}

let controller = Controller.shared
var args = Array(CommandLine.arguments.dropFirst())
while !args.isEmpty {
    let a = args.removeFirst()
    switch a {
    case "--now": controller.startNow = true
    case "--window": controller.startWindow = args.isEmpty ? nil : CGWindowID(args.removeFirst())
    case let x where x.hasPrefix("-psn"): break   // o Finder antigo passa isto
    default: print("Opção desconhecida: \(a)"); exit(1)
    }
}
let app = NSApplication.shared
app.setActivationPolicy(.regular)
app.delegate = controller
app.run()
