import SwiftUI
import AppKit

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

    init() { selected = bottles.first; reload(); autoUpdate() }

    // Ao abrir: atualiza o comando winmac, as ferramentas e o próprio app pelo GitHub; se o app mudou, reabre
    func autoUpdate() {
        let appPath = Bundle.main.bundlePath
        DispatchQueue.global(qos: .utility).async {
            guard FileManager.default.fileExists(atPath: winmacScript) else { return }
            let out = runWinmac(["update", appPath])
            guard out.contains("APP_ATUALIZADO") else { return }
            DispatchQueue.main.async {
                self.status = "Nova versão do WinMac instalada. Reabrindo…"
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/bin/sh")
                p.arguments = ["-c", "sleep 1; open \"$0\"", appPath]
                try? p.run()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { NSApp.terminate(nil) }
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
        if b.isMac { NSWorkspace.shared.open(URL(string: "steam://rungameid/\(g.id)")!); status = "Abrindo \(g.name)…"; return }
        run(["play", g.id, b.id])
    }

    func reload() {
        bottles = loadBottles()
        if selected == nil { selected = bottles.first }
        games = selected.map(loadGames) ?? []
    }

    func installSteam() {
        installing = true
        status = "Preparando…"
        let name = selected?.id ?? "Steam"
        DispatchQueue.global().async {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/bash")
            p.arguments = [winmacScript, "setup", name]
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
            DispatchQueue.main.async {
                self.installing = false
                self.selected = nil
                self.reload()
                if self.selected == nil { self.selected = self.bottles.first { $0.id == name } }
            }
        }
    }

    func run(_ args: [String]) {
        status = "Abrindo…"
        DispatchQueue.global().async {
            let out = runWinmac(args)
            DispatchQueue.main.async { self.status = out }
        }
    }
}

struct GameCard: View {
    let game: Game
    let action: () -> Void
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
            Text(model.status).font(.caption).foregroundStyle(.secondary).lineLimit(2)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle("WinMac")
    }
}

struct ContentView: View {
    @StateObject var model = Model()

    var body: some View {
        NavigationSplitView {
            List(model.bottles, selection: $model.selected) { b in
                Label(b.isMac || b.id != "Steam" ? b.id : "Steam (Windows)", systemImage: b.isMac ? "apple.logo" : "pc").tag(b)
            }
            .navigationTitle("Bottles")
            .onChange(of: model.selected) { _, _ in model.reload() }
        } detail: {
            if !model.steamInstalled {
                InstallView(model: model)
            } else {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 12) {
                    Button { model.openSteam() } label: {
                        Label("Abrir Steam", systemImage: "play.fill").padding(.horizontal, 8)
                    }
                    .controlSize(.large).buttonStyle(.borderedProminent)
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
                        Text("Nenhum jogo instalado neste bottle.").foregroundStyle(.secondary).padding(40)
                    }
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 20)], spacing: 24) {
                        ForEach(model.games) { g in
                            GameCard(game: g) { model.play(g) }
                        }
                    }
                    .padding(20)
                }
            }
            .navigationTitle(model.selected?.id ?? "WinMac")
            }
        }
        .frame(minWidth: 820, minHeight: 560)
    }
}

@main
struct WinMacApp: App {
    var body: some Scene {
        WindowGroup("WinMac") { ContentView() }
    }
}
