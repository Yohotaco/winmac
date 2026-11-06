import SwiftUI
import AppKit
import UniformTypeIdentifiers

let home = FileManager.default.homeDirectoryForCurrentUser.path
let winmacScript = "\(home)/winmac/winmac"
let bottlesDir = "\(home)/winmac/Bottles"
let steamSubdir = "drive_c/Program Files (x86)/Steam"
let hiddenApps: Set<String> = ["228980"] // Steamworks Common Redistributables
// Steam nativa do macOS: os jogos dela aparecem no WinMac e abrem pela própria Steam do Mac
let macSteamDir = "\(home)/Library/Application Support/Steam"
let macSteamName = "Steam do Mac"

struct Game: Identifiable {
    let id: String
    let name: String
    let cover: NSImage?
    var path: String? = nil   // programas de fora da Steam: o .exe ou atalho
}

struct Bottle: Identifiable, Hashable {
    let id: String
    var isMac = false
    var path: String { isMac ? macSteamDir : "\(bottlesDir)/\(id)" }
    /// Pasta da Steam: no Mac é a própria pasta; nos bottles fica dentro do drive C:
    var steamDir: String { isMac ? macSteamDir : "\(path)/\(steamSubdir)" }
}

func loadBottles() -> [Bottle] {
    let names = (try? FileManager.default.contentsOfDirectory(atPath: bottlesDir)) ?? []
    var list = names.filter { !$0.hasPrefix(".") }.sorted().map { Bottle(id: $0) }
    // Sem nenhuma Steam de Windows ainda: mostra o bottle "Steam" para aparecer o botão Instalar Steam
    if list.isEmpty { list.append(Bottle(id: "Steam")) }
    if FileManager.default.fileExists(atPath: "\(macSteamDir)/steamapps") { list.append(Bottle(id: macSteamName, isMac: true)) }
    return list
}

func acfValue(_ key: String, in text: String) -> String? {
    let pattern = "\"\(key)\"\\s*\"([^\"]*)\""
    guard let re = try? NSRegularExpression(pattern: pattern),
          let m = re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
          let r = Range(m.range(at: 1), in: text) else { return nil }
    return String(text[r]).trimmingCharacters(in: .whitespaces)
}

func coverImage(for appid: String, steamDir: String) -> NSImage? {
    let dir = "\(steamDir)/appcache/librarycache/\(appid)"
    for name in ["library_600x900.jpg", "library_capsule.jpg", "header.jpg", "library_header.jpg"] {
        if let img = NSImage(contentsOfFile: "\(dir)/\(name)") { return img }
    }
    // Fallback: o maior arquivo de imagem da pasta
    let files = (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []
    let images = files.compactMap { NSImage(contentsOfFile: "\(dir)/\($0)") }
    return images.max { $0.size.height < $1.size.height }
}

func loadGames(_ bottle: Bottle) -> [Game] {
    let steamDir = bottle.steamDir
    let apps = "\(steamDir)/steamapps"
    let files = (try? FileManager.default.contentsOfDirectory(atPath: apps)) ?? []
    return files.filter { $0.hasPrefix("appmanifest_") && $0.hasSuffix(".acf") }.compactMap { f in
        guard let text = try? String(contentsOfFile: "\(apps)/\(f)", encoding: .utf8),
              let id = acfValue("appid", in: text), !hiddenApps.contains(id) else { return nil }
        let name = acfValue("name", in: text) ?? id
        return Game(id: id, name: name, cover: coverImage(for: id, steamDir: steamDir))
    }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
}

// Programas de fora da Steam: os arrastados para o app e os atalhos criados por instaladores
func programsFile(_ b: Bottle) -> String { "\(b.path)/.winmac-programs" }
let ignoredShortcut = try! NSRegularExpression(pattern: "unins|desinstal|readme|leia-me|help|ajuda|manual|website|support|suporte|licen[sç]|updater|atualizador|error report|recovery|^steam$", options: .caseInsensitive)

func loadPrograms(_ b: Bottle) -> [Game] {
    if b.isMac { return [] }
    let fm = FileManager.default
    var hidden = Set<String>(), seen = Set<String>(), out: [Game] = []
    let lines = ((try? String(contentsOfFile: programsFile(b), encoding: .utf8)) ?? "").split(separator: "\n")
    for line in lines {
        let parts = line.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 2 else { continue }
        if parts[0].isEmpty { hidden.insert(parts[1]); continue }
        if fm.fileExists(atPath: parts[1]) && seen.insert(parts[0]).inserted {
            out.append(Game(id: parts[1], name: parts[0], cover: nil, path: parts[1]))
        }
    }
    let c = "\(b.path)/drive_c"
    var roots = ["\(c)/ProgramData/Microsoft/Windows/Start Menu", "\(c)/users/Public/Desktop"]
    for u in (try? fm.contentsOfDirectory(atPath: "\(c)/users")) ?? [] {
        roots.append("\(c)/users/\(u)/AppData/Roaming/Microsoft/Windows/Start Menu")
    }
    for root in roots {
        guard let files = fm.enumerator(atPath: root) else { continue }
        for case let f as String in files where f.lowercased().hasSuffix(".lnk") {
            let name = ((f as NSString).lastPathComponent as NSString).deletingPathExtension
            let range = NSRange(name.startIndex..., in: name)
            if ignoredShortcut.firstMatch(in: name, range: range) != nil || hidden.contains(name) { continue }
            if seen.insert(name).inserted {
                let path = "\(root)/\(f)"
                out.append(Game(id: path, name: name, cover: nil, path: path))
            }
        }
    }
    return out
}

@discardableResult
func runWinmac(_ args: [String]) -> String {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/bash")
    p.arguments = [winmacScript] + args
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = pipe
    try? p.run()
    p.waitUntilExit()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
}

final class Model: ObservableObject {
    @Published var bottles: [Bottle] = loadBottles()
    @Published var selected: Bottle?
    @Published var games: [Game] = []
    @Published var status = ""
    @Published var installing = false
    @Published var newVersion: String?
    @Published var updateError: String?
    private var lastUpdateCheck: Date?

    init() { selected = bottles.first; reload(); checkForUpdate() }

    // Pergunta antes de atualizar. Confere ao abrir e, no máximo uma vez por hora, ao voltar para a janela.
    func checkForUpdate() {
        if let last = lastUpdateCheck, Date().timeIntervalSince(last) < 3600 { return }
        lastUpdateCheck = Date()
        guard let url = URL(string: "https://api.github.com/repos/Yohotaco/winmac/releases/latest") else { return }
        URLSession.shared.dataTask(with: url) { data, _, _ in
            guard let data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tag = json["tag_name"] as? String else { return }
            let latest = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
            let current = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
            guard latest.compare(current, options: .numeric) == .orderedDescending else { return }
            DispatchQueue.main.async { self.newVersion = latest }
        }.resume()
    }

    func update() {
        let appPath = Bundle.main.bundlePath
        status = "Atualizando o WinMac…"
        DispatchQueue.global(qos: .userInitiated).async {
            let out = runWinmac(["update", appPath])
            DispatchQueue.main.async {
                guard out.contains("APP_ATUALIZADO") else {
                    let reason = out.components(separatedBy: "\n").first { $0.hasPrefix("UPDATE_ERRO ") }
                    self.status = ""
                    self.updateError = reason.map { String($0.dropFirst(12)) } ?? "Baixe a versão nova pelo site."
                    return
                }
                self.status = "Nova versão instalada. Reabrindo…"
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/bin/sh")
                p.arguments = ["-c", "sleep 1; open \"$0\"", appPath]
                try? p.run()
                // exit em vez de terminate: um aviso aberto em outra janela faria o macOS recusar o fechamento
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { exit(0) }
            }
        }
    }

    var steamInstalled: Bool {
        guard let b = selected else { return false }
        if b.isMac { return true }
        return FileManager.default.fileExists(atPath: "\(b.path)/\(steamSubdir)/steam.exe")
    }

    // Steam do Mac: abre pela própria Steam (steam://), versão nativa do jogo
    func openSteam() {
        guard let b = selected else { return }
        if b.isMac { NSWorkspace.shared.open(URL(string: "steam://open/games")!); status = "Steam do Mac aberta"; return }
        run(["steam", b.id])
    }

    func play(_ g: Game) {
        guard let b = selected else { return }
        if let path = g.path { run(["run", path, b.id]); return }
        if b.isMac { NSWorkspace.shared.open(URL(string: "steam://rungameid/\(g.id)")!); status = "Abrindo \(g.name)…"; return }
        run(["play", g.id, b.id])
    }

    func reload() {
        bottles = loadBottles()
        if selected == nil { selected = bottles.first }
        games = (selected.map { loadGames($0) + loadPrograms($0) } ?? [])
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    // Arrastou uma pasta ou .exe para a janela. A Steam do Mac não roda Windows: usa um bottle de Windows.
    func addDropped(_ url: URL) {
        let b = (selected?.isMac == true ? bottles.first { !$0.isMac } : selected) ?? Bottle(id: "Steam")
        selected = b
        status = "Adicionando \(url.lastPathComponent)…"
        stream(["add", url.path, b.id]) { self.reload() }
    }

    // Só tira da lista: os arquivos do programa continuam onde estão
    func remove(_ g: Game) {
        guard let b = selected, let path = g.path else { return }
        let file = programsFile(b)
        var lines = ((try? String(contentsOfFile: file, encoding: .utf8)) ?? "")
            .split(separator: "\n").map(String.init).filter { !$0.hasSuffix("\t\(path)") }
        if path.lowercased().hasSuffix(".lnk") { lines.append("\t\(g.name)") }
        try? (lines.joined(separator: "\n") + "\n").write(toFile: file, atomically: true, encoding: .utf8)
        reload()
    }

    func installSteam() {
        installing = true
        status = "Preparando…"
        let name = selected?.id ?? "Steam"
        stream(["setup", name]) {
            self.installing = false
            self.selected = nil
            self.reload()
            if self.selected == nil { self.selected = self.bottles.first { $0.id == name } }
        }
    }

    func run(_ args: [String]) {
        status = "Abrindo…"
        stream(args) { self.reload() }
    }

    // Roda o winmac mostrando a última linha da saída (downloads podem levar minutos)
    func stream(_ args: [String], done: @escaping () -> Void) {
        DispatchQueue.global().async {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/bash")
            p.arguments = [winmacScript] + args
            let pipe = Pipe()
            p.standardOutput = pipe
            p.standardError = pipe
            pipe.fileHandleForReading.readabilityHandler = { h in
                let text = String(data: h.availableData, encoding: .utf8) ?? ""
                let line = text.components(separatedBy: CharacterSet(charactersIn: "\n\r"))
                    .map { $0.trimmingCharacters(in: .whitespaces) }.last { !$0.isEmpty }
                if let line { DispatchQueue.main.async { self.status = line } }
            }
            try? p.run()
            p.waitUntilExit()
            pipe.fileHandleForReading.readabilityHandler = nil
            DispatchQueue.main.async { done() }
        }
    }
}

struct GameCard: View {
    let game: Game
    let action: () -> Void
    var remove: () -> Void = {}
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 6) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8).fill(Color.gray.opacity(0.2))
                    if let img = game.cover {
                        Image(nsImage: img).resizable().aspectRatio(contentMode: .fill)
                    } else {
                        Image(systemName: "gamecontroller.fill").font(.system(size: 40)).foregroundStyle(.secondary)
                    }
                    if hover {
                        Color.black.opacity(0.35)
                        Image(systemName: "play.circle.fill").font(.system(size: 48)).foregroundStyle(.white)
                    }
                }
                .frame(width: 150, height: 225)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .shadow(radius: hover ? 8 : 3)
                Text(game.name).font(.callout).lineLimit(2).frame(width: 150, alignment: .leading)
            }
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help("Jogar \(game.name)")
        .contextMenu {
            if let path = game.path {
                Button("Mostrar no Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) }
                Button("Remover da lista", action: remove)
            }
        }
    }
}

struct InstallView: View {
    @ObservedObject var model: Model

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "gamecontroller.fill").font(.system(size: 64)).foregroundStyle(.tint)
            Text("Bem-vindo ao WinMac").font(.largeTitle.bold())
            Text("Vamos instalar a Steam oficial da Valve num bottle novo.\nO download leva alguns minutos.")
                .multilineTextAlignment(.center).foregroundStyle(.secondary)
            if model.installing {
                ProgressView().controlSize(.large)
            } else {
                Button { model.installSteam() } label: {
                    Label("Instalar Steam", systemImage: "arrow.down.circle.fill").padding(.horizontal, 12)
                }
                .controlSize(.large).buttonStyle(.borderedProminent)
            }
            Text("Ou arraste para esta janela uma pasta ou um .exe de fora da Steam.").font(.callout).foregroundStyle(.secondary)
            Text(model.status).font(.caption).foregroundStyle(.secondary).lineLimit(2)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle("WinMac")
    }
}

// Soltar pasta ou .exe na janela: acende a moldura e mostra o "+" no cursor
struct FileDrop: DropDelegate {
    @Binding var active: Bool
    let onFile: (URL) -> Void

    func validateDrop(info: DropInfo) -> Bool { info.hasItemsConforming(to: [.fileURL]) }
    func dropEntered(info: DropInfo) { active = true }
    func dropExited(info: DropInfo) { active = false }
    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .copy) }
    func performDrop(info: DropInfo) -> Bool {
        active = false
        let providers = info.itemProviders(for: [.fileURL])
        for p in providers {
            _ = p.loadObject(ofClass: URL.self) { url, _ in
                if let url { DispatchQueue.main.async { onFile(url) } }
            }
        }
        return !providers.isEmpty
    }
}

struct ContentView: View {
    @StateObject var model = Model()
    @State private var dropping = false

    var body: some View {
        NavigationSplitView {
            List(model.bottles, selection: $model.selected) { b in
                Label(b.isMac || b.id != "Steam" ? b.id : "Steam (Windows)", systemImage: b.isMac ? "apple.logo" : "pc").tag(b)
            }
            .navigationTitle("Bottles")
            .onChange(of: model.selected) { _, _ in model.reload() }
        } detail: {
            if !model.steamInstalled && model.games.isEmpty {
                InstallView(model: model)
            } else {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 12) {
                    if model.steamInstalled {
                        Button { model.openSteam() } label: {
                            Label("Abrir Steam", systemImage: "play.fill").padding(.horizontal, 8)
                        }
                        .controlSize(.large).buttonStyle(.borderedProminent)
                    } else {
                        Button { model.installSteam() } label: {
                            Label("Instalar Steam", systemImage: "arrow.down.circle.fill").padding(.horizontal, 8)
                        }
                        .controlSize(.large).disabled(model.installing)
                    }
                    if model.selected?.isMac != true {
                        Button { model.run(["kill", model.selected?.id ?? "Steam"]) } label: {
                            Label("Fechar tudo", systemImage: "stop.fill")
                        }
                        .controlSize(.large)
                    }
                    Spacer()
                    Text(model.status).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    Button { model.reload() } label: { Image(systemName: "arrow.clockwise") }
                        .help("Atualizar lista de jogos")
                }
                .padding()
                Divider()
                ScrollView {
                    if model.games.isEmpty {
                        Text("Nenhum jogo instalado neste bottle.").foregroundStyle(.secondary).padding(.top, 40)
                    }
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 20)], spacing: 24) {
                        ForEach(model.games) { g in
                            GameCard(game: g, action: { model.play(g) }, remove: { model.remove(g) })
                        }
                    }
                    .padding(20)
                    Text("Arraste para esta janela uma pasta ou um .exe para adicionar um programa.")
                        .font(.callout).foregroundStyle(.secondary).padding(.bottom, 20)
                }
            }
            .navigationTitle(model.selected?.id ?? "WinMac")
            }
        }
        .frame(minWidth: 820, minHeight: 560)
        .overlay {
            if dropping {
                RoundedRectangle(cornerRadius: 12).strokeBorder(Color.accentColor, lineWidth: 4)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                    .overlay { Label("Solte para abrir no WinMac", systemImage: "arrow.down.app.fill").font(.title2.bold()) }
                    .padding(6)
                    .allowsHitTesting(false)
            }
        }
        .onDrop(of: [.fileURL], delegate: FileDrop(active: $dropping) { model.addDropped($0) })
        // Instaladores criam os atalhos fora do app: atualiza a lista ao voltar para a janela
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in model.reload(); model.checkForUpdate() }
        .alert("Quer atualizar o WinMac?", isPresented: Binding(get: { model.newVersion != nil }, set: { if !$0 { model.newVersion = nil } })) {
            Button("Atualizar") { model.update() }
            Button("Agora não", role: .cancel) {}
        } message: {
            Text("A versão \(model.newVersion ?? "") já está disponível.")
        }
        .alert("Não consegui atualizar", isPresented: Binding(get: { model.updateError != nil }, set: { if !$0 { model.updateError = nil } })) {
            Button("Baixar pelo site") { NSWorkspace.shared.open(URL(string: "https://github.com/Yohotaco/winmac/releases/latest")!) }
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.updateError ?? "")
        }
    }
}

@main
struct WinMacApp: App {
    var body: some Scene {
        WindowGroup("WinMac") { ContentView() }
    }
}
