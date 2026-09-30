import SwiftUI
import UniformTypeIdentifiers

extension Wrapper {
    /// Downloaded/chosen base image, kept outside the bundle so rebuilds keep it.
    var customIconFile: URL { Self.dataRoot.appending(path: "icons/\(id)") }

    /// Final icon (custom or source icon + badge pill), or nil to keep the app's own icon.
    func renderIcon() -> NSImage? {
        let custom = NSImage(contentsOf: customIconFile)
        let badge = badge.trimmingCharacters(in: .whitespaces).uppercased()
        guard custom != nil || !badge.isEmpty, let source else { return nil }
        let base = custom ?? Self.appIcon(source)
        let side = 1024.0
        return NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            base.draw(in: rect)
            let badge = badge.trimmingCharacters(in: .whitespaces).uppercased()
            guard !badge.isEmpty else { return true }
            // Sized like the Dock's notification badge: capitals fill ~half the pill's height.
            // Long labels shrink to fit the available width instead of overflowing.
            func attrs(_ pt: CGFloat) -> [NSAttributedString.Key: Any] {
                [.font: NSFont.systemFont(ofSize: pt, weight: .heavy), .foregroundColor: NSColor.white, .kern: pt * 0.06]
            }
            let text = badge as NSString, padX = 56.0, maxW = side - 280
            let natural = text.size(withAttributes: attrs(180)).width
            let pt = min(180, 180 * (maxW - 2 * padX) / natural)
            let font = NSFont.systemFont(ofSize: pt, weight: .heavy), kern = pt * 0.06
            let textW = text.size(withAttributes: attrs(pt)).width - kern  // kern also trails the last letter
            let w = textW + 2 * padX, h = 180 * 0.7 * 1.9  // fixed height: cap height of 180pt, ×1.9
            // Bottom-right, as tight into the corner as the squircle mask allows (icon spans ~100...924).
            // It can't overhang like a Dock notification badge: macOS 26+ clips to the squircle, shrinks
            // icons that poke outside it onto a gray plate, and rescales shrunken art back to full size.
            // Inset measured against the alpha of a macOS-rendered icon: tightest unclipped value plus margin.
            let inset = 54.0
            let pill = NSRect(x: 924 - inset - w, y: 100 + inset, width: w, height: h)
            // Continuous-curvature (squircle) corners, same family as the app-icon shape.
            let path = RoundedRectangle(cornerRadius: h * 0.26, style: .continuous).path(in: pill).cgPath
            let ctx = NSGraphicsContext.current!.cgContext

            // Flat, opaque fill like the Dock's notification badge, with a soft lift.
            ctx.saveGState()
            ctx.setShadow(offset: CGSize(width: 0, height: -6), blur: 18, color: NSColor.black.withAlphaComponent(0.25).cgColor)
            ctx.addPath(path)
            ctx.setFillColor(badgeColor.cgColor)
            ctx.fillPath()
            ctx.restoreGState()
            // Centre on the capitals, not the line box (which includes descender space).
            text.draw(at: NSPoint(x: pill.midX - textW / 2, y: pill.midY - font.capHeight / 2 + font.descender),
                      withAttributes: attrs(pt))
            return true
        }
    }

    /// The icon as the Dock shows it. Not the bundled .icns: for apps with layered Icon Composer icons
    /// (Claude, Chrome, ...) that's a flattened sRGB fallback that looks noticeably duller.
    /// `app` must be symlink-resolved, or macOS returns a blank placeholder (e.g. /Applications/Safari.app).
    static func appIcon(_ app: URL) -> NSImage {
        NSWorkspace.shared.icon(forFile: app.resolvingSymlinksInPath().path)
    }

    static func writeICNS(_ image: NSImage, to url: URL) throws {
        // Each size at 1x (72 dpi) and 2x (144 dpi); ImageIO drops the Retina variants without the dpi hint.
        let sizes = [16, 32, 128, 256, 512].flatMap { [($0, 72), ($0 * 2, 144)] }
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.icns.identifier as CFString, sizes.count, nil)
        else { throw BuildError(errorDescription: "Can't write icon.") }
        for (px, dpi) in sizes {
            // Display P3, so wide-gamut icon colours aren't squashed into sRGB and come out duller.
            let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.displayP3)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
            image.draw(in: NSRect(x: 0, y: 0, width: px, height: px))
            NSGraphicsContext.restoreGraphicsState()
            let props = [kCGImagePropertyDPIWidth: dpi, kCGImagePropertyDPIHeight: dpi] as CFDictionary
            CGImageDestinationAddImage(dest, ctx.makeImage()!, props)
        }
        guard CGImageDestinationFinalize(dest) else { throw BuildError(errorDescription: "Can't write icon.") }
    }
}

extension NSColor {
    convenience init?(hex: String) {
        guard let v = UInt32(hex.trimmingCharacters(in: CharacterSet(charactersIn: "#")), radix: 16) else { return nil }
        self.init(srgbRed: CGFloat(v >> 16 & 0xFF) / 255, green: CGFloat(v >> 8 & 0xFF) / 255, blue: CGFloat(v & 0xFF) / 255, alpha: 1)
    }

    var hex: String {
        let c = usingColorSpace(.sRGB) ?? .systemRed
        return String(format: "#%02X%02X%02X", Int(c.redComponent * 255), Int(c.greenComponent * 255), Int(c.blueComponent * 255))
    }
}

/// Search sheet for macosicons.com (needs a free API key from docs.macosicons.com).
struct IconSearchView: View {
    var initialQuery: String
    var onPick: (URL) -> Void
    @Environment(\.dismiss) private var dismiss
    @AppStorage("macosiconsAPIKey") private var apiKey = ""  // ponytail: UserDefaults, low-value key; Keychain if that changes
    @State private var query = ""
    @State private var hits: [Hit] = []
    @State private var status: String?

    struct Hit: Decodable, Identifiable {
        var objectID: String
        var appName: String?
        var icnsUrl: URL
        var lowResPngUrl: URL
        var id: String { objectID }
    }

    var body: some View {
        VStack(alignment: .leading) {
            HStack {
                SecureField("API key", text: $apiKey).frame(width: 200)
                Link("Get a free key", destination: URL(string: "https://docs.macosicons.com/api-management")!)
            }
            TextField("Search macosicons.com", text: $query).onSubmit(search)
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 84))]) {
                    ForEach(hits) { hit in
                        Button { onPick(hit.icnsUrl); dismiss() } label: {
                            AsyncImage(url: hit.lowResPngUrl) { $0.resizable().scaledToFit() } placeholder: { ProgressView() }
                                .frame(width: 72, height: 72)
                        }
                        .buttonStyle(.plain)
                        .help(hit.appName ?? "")
                    }
                }
            }
            .frame(minHeight: 300)
            HStack {
                Text(status ?? "\(hits.count) icons").foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }
        .padding()
        .frame(width: 520, height: 460)
        .onAppear { query = initialQuery; if !apiKey.isEmpty { search() } }
    }

    private func search() {
        guard !apiKey.isEmpty else { status = "Enter your API key first."; return }
        status = "Searching…"
        var req = URLRequest(url: URL(string: "https://api.macosicons.com/api/search")!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        req.httpBody = try? JSONSerialization.data(withJSONObject: [
            "query": query, "searchOptions": ["hitsPerPage": 60, "page": 1],
        ])
        Task {
            do {
                let (data, resp) = try await URLSession.shared.data(for: req)
                guard (resp as? HTTPURLResponse)?.statusCode == 200 else {
                    status = "Search failed (HTTP \((resp as? HTTPURLResponse)?.statusCode ?? 0)). Check your API key."
                    return
                }
                struct Response: Decodable { var hits: [Hit] }
                hits = try JSONDecoder().decode(Response.self, from: data).hits
                status = nil
            } catch {
                status = error.localizedDescription
            }
        }
    }
}
