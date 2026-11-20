// mFONTS — interface (design Flat Round, arrondis 8, accent #2C9ED6).
import SwiftUI
import AppKit
import UniformTypeIdentifiers

enum Theme {
    static let acc = Color(red: 0x2C / 255, green: 0x9E / 255, blue: 0xD6 / 255)
    static let r: CGFloat = 8
    private static func dyn(_ dark: UInt32, _ light: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { a in
            let v = a.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: CGFloat((v >> 16) & 255) / 255, green: CGFloat((v >> 8) & 255) / 255, blue: CGFloat(v & 255) / 255, alpha: 1)
        })
    }
    static let nsBg = NSColor(name: nil) { a in
        a.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(srgbRed: 0x13 / 255, green: 0x13 / 255, blue: 0x16 / 255, alpha: 1) : NSColor(srgbRed: 0xf1 / 255, green: 0xf1 / 255, blue: 0xf5 / 255, alpha: 1) }
    static let bg = dyn(0x131316, 0xf1f1f5)
    static let side = dyn(0x18181b, 0xe9e9ee)
    static let line = dyn(0x2f2f35, 0xd7d7de)
    static let card = dyn(0x1d1d21, 0xffffff)
    static let ctl = dyn(0x2c2c31, 0xe8e8ef)
    static let t2 = dyn(0x98989f, 0x6b6b78)
    static let ok = dyn(0x30d158, 0x2fb36a)
}

enum Prompt {
    @MainActor static func text(_ title: String, _ message: String, _ initial: String = "") -> String? {
        let a = NSAlert()
        a.messageText = title; a.informativeText = message
        let f = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24)); f.stringValue = initial
        a.accessoryView = f
        a.addButton(withTitle: L.t("btn.ok")); a.addButton(withTitle: L.t("btn.cancel"))
        a.window.initialFirstResponder = f
        guard a.runModal() == .alertFirstButtonReturn else { return nil }
        let s = f.stringValue.trimmingCharacters(in: .whitespaces)
        return s.isEmpty ? nil : s
    }
}

struct Toggle18: View {
    let on: Bool; let partial: Bool; let action: () -> Void
    var body: some View {
        Button(action: action) {
            ZStack(alignment: on ? .trailing : .leading) {
                Capsule().fill(on || partial ? Theme.ok.opacity(on ? 1 : 0.5) : Theme.ctl).frame(width: 30, height: 18)
                Circle().fill(.white).frame(width: 14, height: 14).padding(2).shadow(radius: 1, y: 1)
            }
        }.buttonStyle(.plain)
    }
}

struct MainView: View {
    @ObservedObject var cat = Catalog.shared
    @AppStorage("viewGrid") var grid = true
    @AppStorage("previewText") var previewText = ""
    @AppStorage("previewMode") var mode = "document"
    @AppStorage("previewScale") var scale = 100.0
    @AppStorage("showFilters") var showFilters = true
    @AppStorage("showInfo") var showInfo = true
    @State var showImport = false
    @State var searching = false
    @FocusState var searchFocus: Bool

    var sample: String {
        switch mode {
        case "alphabet": return "ABCDEFGHIJKLMNOPQRSTUVWXYZ abcdefghijklmnopqrstuvwxyz 0123456789"
        case "pangram": return L.t("prefs.sample")
        case "name": return ""
        case "custom": return previewText.isEmpty ? L.t("prefs.sample") : previewText
        default: return previewText.isEmpty ? L.t("prefs.sample") : previewText
        }
    }

    func icon(_ name: String, on: Bool = false, enabled: Bool = true, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: name).font(.system(size: 14)).frame(width: 28, height: 28)
                .foregroundStyle(on ? Theme.acc : Theme.t2)
                .background(on ? Theme.acc.opacity(0.18) : Color.clear, in: RoundedRectangle(cornerRadius: Theme.r))
        }.buttonStyle(.plain).disabled(!enabled).opacity(enabled ? 1 : 0.4).help(help)
    }

    var body: some View {
        HStack(spacing: 0) {
            SidebarView().frame(width: 230)
            Rectangle().fill(Theme.line).frame(width: 1)
            VStack(spacing: 0) {
                toolbar
                if showFilters { FilterBar() }
                HStack(spacing: 12) {
                    FontGrid(sample: sample, grid: grid, scale: scale)
                    if showInfo, let name = cat.selectedFamily { InspectorView(family: name, sample: sample).frame(minWidth: 280, idealWidth: 320, maxWidth: 360) }
                }.padding([.horizontal, .bottom], 14).padding(.top, showFilters ? 0 : 4)
                Divider().opacity(0.5)
                HStack {
                    Text(L.t("stat.line", cat.familyCount, cat.fonts.count, cat.activeCount))
                    if cat.classifying { Text("· " + L.t("tb.classifying")) }
                    Spacer()
                    if let a = cat.activating {
                        Text(L.t(a.on ? "act.on" : "act.off", a.done, a.total)).monospacedDigit()
                        ProgressView(value: Double(a.done), total: Double(max(a.total, 1))).progressViewStyle(.linear).tint(Theme.acc).frame(width: 180)
                        Spacer()
                    }
                    Text(L.t("stat.shown", cat.visible.count))
                }.font(.system(size: 12)).foregroundStyle(Theme.t2).padding(.horizontal, 14).padding(.vertical, 8)
            }
        }
        .background(Theme.bg)
        .ignoresSafeArea(.container, edges: .top)
        .frame(width: 1180, height: 767)
        .sheet(isPresented: $showImport) { ImportView(isPresented: $showImport) }
        .alert("mFONTS", isPresented: Binding(get: { cat.lastError != nil }, set: { if !$0 { cat.lastError = nil } })) {
            Button(L.t("btn.ok")) {}
        } message: { Text(cat.lastError ?? "") }
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            var urls: [URL] = []; let g = DispatchGroup()
            for p in providers { g.enter(); _ = p.loadObject(ofClass: URL.self) { u, _ in if let u { urls.append(u) }; g.leave() } }
            g.notify(queue: .main) { _ = Catalog.shared.addFiles(urls) }
            return true
        }
    }

    var toolbar: some View {
        HStack(spacing: 10) {
            icon("chevron.left", enabled: cat.canBack, help: L.t("tb.back")) { cat.go(-1) }
            icon("chevron.right", enabled: cat.canForward, help: L.t("tb.forward")) { cat.go(1) }
            Text("Aa").font(.system(size: 12)).foregroundStyle(Theme.t2).padding(.leading, 6)
            Slider(value: $scale, in: 50...200).frame(width: 110).tint(Theme.acc).help(L.t("set.scale", Int(scale)))
            Text("\(Int(scale))").font(.system(size: 12)).foregroundStyle(Theme.t2).monospacedDigit().frame(width: 28, alignment: .leading)
            Menu {
                ForEach(["document", "alphabet", "pangram", "name", "custom"], id: \.self) { m in
                    Button { mode = m } label: { if mode == m { Label(L.t("doc." + m), systemImage: "checkmark") } else { Text(L.t("doc." + m)) } }
                }
            } label: { HStack(spacing: 6) { Image(systemName: "doc.text"); Text(L.t("doc." + mode)) } }
                .menuStyle(.borderlessButton).fixedSize()
                .padding(.horizontal, 10).padding(.vertical, 5).background(Theme.ctl, in: RoundedRectangle(cornerRadius: Theme.r))
            if mode == "custom" {
                TextField(L.t("tb.preview"), text: $previewText).textFieldStyle(.plain).padding(.horizontal, 10).padding(.vertical, 6)
                    .frame(width: 190).background(Theme.ctl, in: RoundedRectangle(cornerRadius: Theme.r))
            }
            Spacer(minLength: 8)
            if searching || !cat.search.isEmpty {
                HStack(spacing: 6) { Image(systemName: "magnifyingglass").foregroundStyle(Theme.t2)
                    TextField(L.t("tb.search"), text: $cat.search).textFieldStyle(.plain).focused($searchFocus)
                    Button { cat.search = ""; searching = false } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.t2) }.buttonStyle(.plain) }
                    .padding(.horizontal, 10).padding(.vertical, 6).frame(width: 220).background(Theme.ctl, in: RoundedRectangle(cornerRadius: Theme.r))
            }
            icon("magnifyingglass", on: searching, help: L.t("tb.search")) { searching.toggle(); if searching { DispatchQueue.main.async { searchFocus = true } } }
            icon("line.3.horizontal.decrease", on: showFilters || cat.filtersActive, help: L.t("tb.filter")) { showFilters.toggle() }
            icon(grid ? "square.grid.2x2" : "list.bullet", help: grid ? L.t("tb.viewList") : L.t("tb.viewGrid")) { grid.toggle() }
            Menu {
                ForEach(SortKey.allCases, id: \.self) { k in
                    Button { cat.sortKey = k } label: { if cat.sortKey == k { Label(L.t("sort." + k.rawValue), systemImage: "checkmark") } else { Text(L.t("sort." + k.rawValue)) } }
                }
                Divider()
                Button { cat.sortAsc = true } label: { if cat.sortAsc { Label(L.t("sort.asc"), systemImage: "checkmark") } else { Text(L.t("sort.asc")) } }
                Button { cat.sortAsc = false } label: { if !cat.sortAsc { Label(L.t("sort.desc"), systemImage: "checkmark") } else { Text(L.t("sort.desc")) } }
            } label: { Image(systemName: "arrow.up.arrow.down").font(.system(size: 14)).foregroundStyle(Theme.t2).frame(width: 28, height: 28) }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().help(L.t("tb.sort"))
            icon("info.circle", on: showInfo, help: L.t("tb.info")) { showInfo.toggle() }
            Button(L.t("tb.import")) { showImport = true }.fixedSize()
            Button(L.t("tb.add")) { addFonts() }.buttonStyle(.borderedProminent).tint(Theme.acc).fixedSize()
        }.padding(.horizontal, 14).frame(height: 52)
    }

    func addFonts() {
        let p = NSOpenPanel(); p.allowsMultipleSelection = true; p.canChooseDirectories = true
        p.allowedContentTypes = [.font, .folder]
        if p.runModal() == .OK { _ = cat.addFiles(p.urls) }
    }
}

// MARK: barre de filtres (puces)

struct FilterBar: View {
    @ObservedObject var cat = Catalog.shared
    static let langs = ["fr", "en", "es", "it", "de", "pt", "nl", "pl", "sv", "tr", "ru", "el", "ja", "zh", "ar", "hi", "vi"]
    static let classes = ["serif", "sans", "script", "mono", "display", "symbol", "other"]

    func chip(_ title: String, on: Bool = false, menu: Bool = false) -> some View {
        HStack(spacing: 4) { Text(title); if menu { Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold)) } else if on { Image(systemName: "xmark").font(.system(size: 9, weight: .bold)) } }
            .font(.system(size: 13)).foregroundStyle(on ? Theme.acc : Theme.t2)
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(on ? Theme.acc.opacity(0.18) : Color.clear, in: RoundedRectangle(cornerRadius: Theme.r))
            .contentShape(Rectangle())
    }
    func check(_ t: String, _ on: Bool) -> some View { on ? AnyView(Label(t, systemImage: "checkmark")) : AnyView(Text(t)) }

    var body: some View {
        HStack(spacing: 4) {
            Button { cat.onlyFavorites.toggle() } label: {
                Image(systemName: cat.onlyFavorites ? "star.fill" : "star").frame(width: 28, height: 28)
                    .foregroundStyle(cat.onlyFavorites ? Color.yellow : Theme.t2)
            }.buttonStyle(.plain).help(L.t("more.fav"))
            Menu {
                Button { cat.status = 0 } label: { check(L.t("st.all"), cat.status == 0) }
                Button { cat.status = 1 } label: { check(L.t("st.active"), cat.status == 1) }
                Button { cat.status = 2 } label: { check(L.t("st.inactive"), cat.status == 2) }
            } label: { chip(cat.status == 0 ? L.t("chip.status") : L.t(cat.status == 1 ? "st.active" : "st.inactive"), on: cat.status != 0, menu: true) }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            ForEach(Self.classes.filter { cat.clsFilter.contains($0) }, id: \.self) { c in
                Button { cat.clsFilter.remove(c) } label: { chip(L.t("cls." + c), on: true) }.buttonStyle(.plain)
            }
            Rectangle().fill(Theme.line).frame(width: 1, height: 16).padding(.horizontal, 4)
            Menu {
                ForEach(Self.classes, id: \.self) { c in
                    Button { if cat.clsFilter.contains(c) { cat.clsFilter.remove(c) } else { cat.clsFilter.insert(c) } } label: { check(L.t("cls." + c), cat.clsFilter.contains(c)) }
                }
            } label: { chip(L.t("chip.props"), menu: true) }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            Menu {
                Button { cat.langFilter = nil } label: { check(L.t("st.all"), cat.langFilter == nil) }
                Divider()
                ForEach(Self.langs, id: \.self) { l in Button { cat.langFilter = l } label: { check(L.t("lang." + l), cat.langFilter == l) } }
            } label: { chip(cat.langFilter.map { L.t("lang." + $0) } ?? L.t("chip.lang"), on: cat.langFilter != nil, menu: true) }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            Menu {
                Button { cat.onlyFavorites.toggle() } label: { check(L.t("more.fav"), cat.onlyFavorites) }
                Button { cat.onlyItalic.toggle() } label: { check(L.t("more.italic"), cat.onlyItalic) }
            } label: { chip(L.t("chip.more"), on: cat.onlyItalic, menu: true) }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            if cat.filtersActive { Button { cat.clearFilters() } label: { chip(L.t("chip.clear")) }.buttonStyle(.plain) }
            Button {
                if let n = Prompt.text(L.t("chip.save.title"), L.t("chip.savename")) { cat.saveVisibleAsCollection(n) }
            } label: { chip(L.t("chip.save")) }.buttonStyle(.plain).disabled(cat.visible.isEmpty)
            Spacer()
            Text(L.t("chip.count", cat.visible.count, cat.familyCount)).font(.system(size: 12)).foregroundStyle(Theme.t2)
        }.padding(.horizontal, 14).frame(height: 40)
    }
}

// MARK: barre latérale

struct SidebarView: View {
    @ObservedObject var cat = Catalog.shared

    func row(_ title: String, _ sel: Sidebar, count: String, color: Color? = nil, icon: String? = nil) -> some View {
        let on = cat.selection == sel
        return HStack(spacing: 8) {
            if let color { RoundedRectangle(cornerRadius: 3).fill(color).frame(width: 9, height: 9) }
            if let icon { Image(systemName: icon).frame(width: 16) }
            Text(title).lineLimit(1)
            Spacer()
            Text(Catalog.shared.counts[count].map { $0.formatted() } ?? "0").font(.system(size: 11.5)).opacity(0.7).monospacedDigit()
        }
                .padding(.horizontal, 9).padding(.vertical, 6)
        .foregroundStyle(on ? Color.white : Color.primary)
        .background(on ? Theme.acc : Color.clear, in: RoundedRectangle(cornerRadius: Theme.r))
        .contentShape(Rectangle())
        .onTapGesture {
            cat.selection = sel
            if sel == .all { UserDefaults.standard.set(true, forKey: "viewGrid"); cat.selectedFamily = nil }
        }
    }

    func head(_ t: String, plus: (() -> Void)? = nil) -> some View {
        HStack { Text(t.uppercased()).font(.system(size: 10.5, weight: .semibold)).foregroundStyle(Theme.t2); Spacer()
            if let plus { Button(action: plus) { Image(systemName: "plus") }.buttonStyle(.plain).foregroundStyle(Theme.t2) } }
            .padding(.leading, 8).padding(.top, 10)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 1) {
                row(L.t("side.all"), .all, count: "all", icon: "textformat")
                row(L.t("side.fav"), .favorites, count: "fav", icon: "star")
                row(L.t("side.recent"), .recent, count: "rec", icon: "clock")
                row(L.t("side.dups"), .duplicates, count: "dup", icon: "square.on.square")
                head(L.t("side.libs"))
                ForEach(Array(cat.libs.enumerated()), id: \.element.id) { _, l in
                    row(l.name, .library(l.id), count: "lib:" + l.id, icon: "character.book.closed")
                        .contextMenu {
                            let members = cat.fonts.filter { $0.lib == l.id }
                            let allOn = !members.isEmpty && members.allSatisfy(\.enabled)
                            Button(allOn ? L.t("ctx.deactivate") : L.t("ctx.activate")) { cat.setActive(members, on: !allOn) }
                                .disabled(members.isEmpty)
                        }
                }
                head(L.t("side.sets"))
                row(L.t("side.active"), .active, count: "act", icon: "checkmark.circle")
                row(L.t("side.inactive"), .inactive, count: "ina", icon: "circle")
                head(L.t("side.collections")) { if let n = Prompt.text(L.t("coll.new"), L.t("coll.name")) { cat.createCollection(n) } }
                ForEach(cat.collections) { c in
                    row(c.name, .collection(c.id), count: "col:" + c.id, icon: "folder")
                        .contextMenu {
                            let members = cat.fonts.filter { cat.collFonts[c.id]?.contains($0.id) == true }
                            let allOn = !members.isEmpty && members.allSatisfy(\.enabled)
                            Button(allOn ? L.t("ctx.deactivate") : L.t("ctx.activate")) { cat.setActive(members, on: !allOn) }
                                .disabled(members.isEmpty)
                            Divider()
                            Button(L.t("coll.rename")) { if let n = Prompt.text(L.t("coll.rename"), L.t("coll.name"), c.name) { cat.renameCollection(c.id, n) } }
                            Button(L.t("coll.delete"), role: .destructive) { cat.deleteCollection(c.id) }
                        }
                }
                if !cat.tags.isEmpty {
                    head(L.t("side.tags"))
                    ForEach(cat.tags) { t in row(t.name, .tag(t.id), count: "tag:" + t.id, icon: "tag") }
                }
            }.padding(.horizontal, 10).padding(.bottom, 10).padding(.top, 46)
        }
        .background(Theme.side)
        .font(.system(size: 13))
    }
}

extension Color {
    init(hex: String) {
        let v = UInt32(hex.dropFirst(), radix: 16) ?? 0x888888
        self.init(red: Double((v >> 16) & 255) / 255, green: Double((v >> 8) & 255) / 255, blue: Double(v & 255) / 255)
    }
}

// MARK: grille / liste

struct FontGrid: View {
    @ObservedObject var cat = Catalog.shared
    let sample: String; let grid: Bool; let scale: Double

    var body: some View {
        ScrollView {
            if grid {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 300, maximum: .infinity), spacing: 10)], spacing: 10) {
                    ForEach(cat.visible) { FamilyCard(family: $0, sample: sample, scale: scale, compact: false) }
                }
            } else {
                LazyVStack(spacing: 6) { ForEach(cat.visible) { FamilyCard(family: $0, sample: sample, scale: scale, compact: true) } }
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct FamilyCard: View {
    @ObservedObject var cat = Catalog.shared
    let family: Family; let sample: String; let scale: Double; let compact: Bool

    var body: some View {
        let rep = family.rep
        let sel = cat.selectedFamily == family.id
        let ok = FontCache.exists(rep)
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                Circle().strokeBorder(family.enabledCount > 0 ? Theme.ok : Theme.t2, lineWidth: 1.5).background(Circle().fill(family.allEnabled ? Theme.ok : .clear)).frame(width: 8, height: 8)
                    .padding(4).contentShape(Rectangle()).onTapGesture { cat.setActive(family.fonts, on: !family.allEnabled) }
                    .help(family.allEnabled ? L.t("ctx.deactivate") : L.t("ctx.activate"))
                Text(family.id + " · " + (family.fonts.count == 1 ? L.t("card.style") : L.t("card.styles", family.fonts.count))).lineLimit(1)
                if family.starred { Image(systemName: "star.fill").foregroundStyle(.yellow).font(.system(size: 10)) }
                Spacer()
            }.font(.system(size: 12)).foregroundStyle(Theme.t2)
            Text(sample.isEmpty ? family.id : sample).font(FontCache.font(rep, size: 28 * scale / 100)).lineLimit(1).minimumScaleFactor(0.4)
                .frame(maxWidth: .infinity, minHeight: 36 * scale / 100, maxHeight: 36 * scale / 100, alignment: .leading).clipped().opacity(ok ? 1 : 0.35)
        }
        .padding(.vertical, compact ? 8 : 10).padding(.horizontal, 14)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: Theme.r))
        .overlay(RoundedRectangle(cornerRadius: Theme.r).stroke(sel ? Theme.acc : Theme.line, lineWidth: sel ? 2 : 1))
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { cat.selectedFamily = family.id; cat.setActive(family.fonts, on: !family.allEnabled) }
        .onTapGesture { cat.selectedFamily = family.id }
        .contextMenu { FamilyMenu(fonts: family.fonts) }
    }
}

struct FamilyMenu: View {
    @ObservedObject var cat = Catalog.shared
    let fonts: [FontRec]
    var body: some View {
        let allOn = fonts.allSatisfy(\.enabled)
        Button(allOn ? L.t("ctx.deactivate") : L.t("ctx.activate")) { cat.setActive(fonts, on: !allOn) }
        Button(fonts.contains(where: \.starred) ? L.t("ctx.unfav") : L.t("ctx.fav")) { cat.setStar(fonts, !fonts.contains(where: \.starred)) }
        Menu(L.t("ctx.addColl")) {
            ForEach(cat.collections) { c in Button(c.name) { cat.add(fonts, toCollection: c.id) } }
            Divider()
            Button(L.t("ctx.newColl")) { if let n = Prompt.text(L.t("coll.new"), L.t("coll.name")) { cat.createCollection(n, adding: fonts) } }
        }
        if case .collection(let id) = cat.selection { Button(L.t("ctx.removeColl")) { cat.remove(fonts, fromCollection: id) } }
        Menu(L.t("ctx.tag")) {
            ForEach(cat.tags) { t in Button(t.name) { cat.add(fonts, toTag: t.id) } }
            Divider()
            Button(L.t("ctx.newTag")) { if let n = Prompt.text(L.t("tag.new"), L.t("tag.name")) { cat.createTag(n, adding: fonts) } }
        }
        if case .tag(let id) = cat.selection { Button(L.t("ctx.untag")) { cat.remove(fonts, fromTag: id) } }
        Divider()
        Button(L.t("ctx.reveal")) { NSWorkspace.shared.activateFileViewerSelecting(fonts.map(\.url)) }
    }
}

// MARK: inspecteur

struct InspectorView: View {
    @ObservedObject var cat = Catalog.shared
    let family: String; let sample: String

    var body: some View {
        let fonts = cat.fonts.filter { $0.family == family }.sorted { ($0.weight, $0.italic ? 1 : 0, $0.style) < ($1.weight, $1.italic ? 1 : 0, $1.style) }
        ScrollView {
            if let rep = fonts.first(where: { $0.style.lowercased() == "regular" }) ?? fonts.first {
                let extra = cat.extra(rep.id)
                VStack(alignment: .leading, spacing: 10) {
                    box {
                        Text(family).font(FontCache.font(rep, size: 44)).lineLimit(1).minimumScaleFactor(0.3)
                        HStack(spacing: 6) {
                            Text(family).fontWeight(.semibold)
                            if fonts.contains(where: \.enabled) { chip(L.t("insp.active"), Theme.ok) }
                            chip(rep.type, Theme.ctl)
                        }
                        Text("\(rep.designer.isEmpty ? "—" : rep.designer) · \(cat.libName(rep.lib))").font(.system(size: 11.5)).foregroundStyle(Theme.t2)
                    }
                    box {
                        title(L.t("insp.styles") + " (\(fonts.count))")
                        ForEach(fonts) { f in
                            HStack {
                                Text(f.style).font(FontCache.font(f, size: 18)).lineLimit(1)
                                Spacer()
                                Toggle18(on: f.enabled, partial: false) { cat.setActive([f], on: !f.enabled) }
                            }.padding(.vertical, 3)
                            Divider().opacity(0.3)
                        }
                    }
                    box {
                        title(L.t("insp.glyphs"))
                        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 8), spacing: 4) {
                            ForEach(Array("ABCDEÉÆ&abgéœ12€".enumerated()), id: \.offset) { _, ch in
                                Text(String(ch)).font(FontCache.font(rep, size: 20)).frame(maxWidth: .infinity).padding(.vertical, 4)
                                    .background(Theme.ctl, in: RoundedRectangle(cornerRadius: 6))
                            }
                        }
                    }
                    box {
                        info(L.t("insp.license"), extra.licenseURL.isEmpty ? (extra.license.isEmpty ? "—" : String(extra.license.prefix(80))) : extra.licenseURL)
                        info(L.t("insp.languages"), extra.langs.split(separator: ",").prefix(8).joined(separator: " · "))
                        info(L.t("insp.file"), URL(fileURLWithPath: rep.path).lastPathComponent)
                        let cs = cat.fontCollsFor(rep).map(\.name).joined(separator: ", ")
                        info(L.t("insp.collections"), cs.isEmpty ? L.t("insp.none") : cs)
                        let ts = cat.fontTagsFor(rep).map(\.name).joined(separator: ", ")
                        info(L.t("insp.tags"), ts.isEmpty ? L.t("insp.none") : ts)
                        if !FileManager.default.fileExists(atPath: rep.path) { Text(L.t("insp.missing")).font(.system(size: 11.5)).foregroundStyle(.orange) }
                    }
                }
            } else { Text(L.t("insp.empty")).foregroundStyle(Theme.t2) }
        }
    }

    func box<C: View>(@ViewBuilder _ c: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 6) { c() }.frame(maxWidth: .infinity, alignment: .leading).padding(12)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: Theme.r))
    }
    func title(_ t: String) -> some View { Text(t.uppercased()).font(.system(size: 10.5, weight: .semibold)).foregroundStyle(Theme.t2) }
    func chip(_ t: String, _ c: Color) -> some View {
        Text(t).font(.system(size: 10.5, weight: .semibold)).padding(.horizontal, 8).padding(.vertical, 2).background(c.opacity(0.3), in: Capsule())
    }
    func info(_ k: String, _ v: String) -> some View {
        HStack(alignment: .top) { Text(k).foregroundStyle(Theme.t2); Spacer(); Text(v).multilineTextAlignment(.trailing).lineLimit(2) }.font(.system(size: 12))
    }
}

// MARK: import Right Fonts

struct ImportView: View {
    @Binding var isPresented: Bool
    @State var folder: URL? = RightFontImporter.defaultFolder()
    @State var libs: [RFLibrary] = []
    @State var options = ImportOptions()
    @State var running = false
    @State var progress = 0.0
    @State var status = ""
    @State var report: ImportReport?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L.t("imp.title")).font(.system(size: 18, weight: .bold))
            HStack {
                Text(folder?.path ?? "—").font(.system(size: 11.5)).foregroundStyle(Theme.t2).lineLimit(1).truncationMode(.middle)
                    .padding(8).frame(maxWidth: .infinity, alignment: .leading).background(Theme.ctl, in: RoundedRectangle(cornerRadius: Theme.r))
                Button(L.t("imp.choose")) { choose() }.disabled(running)
            }
            if libs.isEmpty { Text(L.t("imp.none")).foregroundStyle(Theme.t2) }
            else {
                HStack(alignment: .top, spacing: 14) {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack { Text(L.t("imp.libs").uppercased()).font(.system(size: 10.5, weight: .semibold)).foregroundStyle(Theme.t2); Spacer()
                            Button(L.t("imp.all")) { options.libs = Set(libs.map(\.id)) }.buttonStyle(.link).font(.system(size: 11)) }
                        ScrollView { VStack(spacing: 2) { ForEach(libs) { l in
                            Toggle(isOn: Binding(get: { options.libs.contains(l.id) }, set: { if $0 { options.libs.insert(l.id) } else { options.libs.remove(l.id) } })) {
                                HStack { Text(l.name); Spacer(); Text(l.count.formatted()).foregroundStyle(Theme.t2) }
                            }
                        } } }
                    }.padding(12).background(Theme.card, in: RoundedRectangle(cornerRadius: Theme.r)).frame(height: 240)
                    VStack(alignment: .leading, spacing: 6) {
                        Toggle(L.t("imp.coll"), isOn: $options.collections)
                        Toggle(L.t("imp.tags"), isOn: $options.tags)
                        Toggle(L.t("imp.fav"), isOn: $options.favorites)
                        Toggle(L.t("imp.active"), isOn: $options.activate)
                        Toggle(L.t("imp.prefs"), isOn: $options.prefs)
                        Spacer()
                        Text(L.t("imp.mode")).font(.system(size: 11.5)).foregroundStyle(Theme.t2)
                    }.padding(12).frame(maxWidth: .infinity, alignment: .leading).frame(height: 240).background(Theme.card, in: RoundedRectangle(cornerRadius: Theme.r))
                }
            }
            if running { ProgressView(value: progress); Text(L.t("imp.reading", status)).font(.system(size: 11.5)).foregroundStyle(Theme.t2) }
            if let r = report {
                VStack(alignment: .leading, spacing: 2) {
                    Text(L.t("imp.done", r.fonts, r.collections, r.tags, r.activated)).fontWeight(.semibold)
                    if r.duplicates > 0 { Text(L.t("imp.dups", r.duplicates)).foregroundStyle(Theme.t2) }
                    if r.skipped > 0 { Text(L.t("imp.skipped", r.skipped)).foregroundStyle(Theme.t2) }
                    ForEach(r.errors, id: \.self) { Text($0).foregroundStyle(.orange) }
                }.font(.system(size: 12))
            }
            HStack { Spacer()
                Button(report == nil ? L.t("btn.cancel") : L.t("btn.close")) { isPresented = false }.disabled(running)
                Button(L.t("imp.go")) { run() }.buttonStyle(.borderedProminent).tint(Theme.acc).disabled(running || options.libs.isEmpty)
            }
        }
        .padding(20).frame(width: 640).background(Theme.bg)
        .onAppear { scan() }
    }

    func choose() {
        let p = NSOpenPanel(); p.canChooseDirectories = true; p.canChooseFiles = false; p.directoryURL = folder
        if p.runModal() == .OK { folder = p.url; scan() }
    }
    func scan() {
        guard let folder else { return }
        libs = RightFontImporter.detect(in: folder)
        options.libs = Set(libs.map(\.id))
    }
    func run() {
        running = true; report = nil; progress = 0
        let libsCopy = libs, opts = options
        Task {
            let payload = await Task.detached(priority: .userInitiated) {
                RightFontImporter.read(libsCopy, options: opts) { p, s in Task { @MainActor in progress = p; status = s } }
            }.value
            let rep = Catalog.shared.apply(payload, options: opts)
            FontCache.reset()
            report = rep; running = false
        }
    }
}

// MARK: réglages

struct SettingsView: View {
    @AppStorage("persistentActivation") var persistent = true
    @AppStorage("presence") var presence = "both"
    @AppStorage("autoUpdate") var autoUpdate = true
    @AppStorage("previewText") var previewText = ""
    @AppStorage("previewScale") var scale = 100.0
    @ObservedObject var up = Updater.shared

    var body: some View {
        Form {
            Section(L.t("set.activation")) { Toggle(L.t("set.persistent"), isOn: $persistent).listRowBackground(Theme.card) }
            Section(L.t("set.presence")) {
                Picker("", selection: $presence) {
                    Text(L.t("presence.both")).tag("both"); Text(L.t("presence.dock")).tag("dock"); Text(L.t("presence.menubar")).tag("menubar")
                }.labelsHidden().pickerStyle(.radioGroup).listRowBackground(Theme.card)
            }
            Section(L.t("set.display")) {
                TextField(L.t("set.sample"), text: $previewText).listRowBackground(Theme.card)
                HStack { Text(L.t("set.scale", Int(scale))); Slider(value: $scale, in: 50...200) }.listRowBackground(Theme.card)
            }
            Section(L.t("upd.title")) {
                Toggle(L.t("upd.auto"), isOn: $autoUpdate).listRowBackground(Theme.card)
                Text(L.t("upd.version", up.currentVersion)).foregroundStyle(.secondary).listRowBackground(Theme.card)
                HStack {
                    Button(L.t("upd.check")) { Task { await up.check() } }
                    if case .available(let v) = up.state { Button(L.t("upd.install", v)) { Task { await up.install() } }.buttonStyle(.borderedProminent) }
                }.listRowBackground(Theme.card)
                Text(statusText).font(.system(size: 12)).foregroundStyle(.secondary).listRowBackground(Theme.card)
            }
        }
        .formStyle(.grouped).scrollContentBackground(.hidden).background(Theme.bg).tint(Theme.acc).frame(width: 460, height: 640)
        .onChange(of: presence) { _, _ in AppDelegate.applyPresence() }
    }

    var statusText: String {
        switch up.state {
        case .idle: return ""
        case .checking: return L.t("upd.checking")
        case .upToDate: return L.t("upd.uptodate", up.currentVersion)
        case .available(let v): return L.t("upd.available", v)
        case .downloading: return L.t("upd.downloading")
        case .failed(let e): return L.t("upd.failed", e)
        }
    }
}
