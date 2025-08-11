//
//  JiraNotesApp.swift
//  JiraNotes
//
//  Created by Peter Mak on 10/8/2025.
//


import SwiftUI
import AppKit

@main
struct JiraNotesApp: App {
    @NSApplicationDelegateAdaptor(NotesAppDelegate.self) var appDelegate
    var body: some Scene { Settings { EmptyView() } }
}

final class AppState: ObservableObject {
    static let shared = AppState()
    @Published var notesDir: URL?
    @Published var port: UInt16 = 18427
    @Published var running = false
}

final class NotesAppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem!
    var menu: NSMenu!
    var server: SimpleHTTPServer?
    
    // MARK: - Menu Helpers

    fileprivate enum MenuTags {
        static let status = 9001
        static let port   = 9002
        static let folder = 9003
    }

    fileprivate func copyToClipboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        setupMenu()
        startServer()
        if let url = Bookmark.store.resolveAndStart() {
            AppState.shared.notesDir = url
        }
        updateFolderMenu()
        updateStatus("Launched")
    }

    func setupMenu() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let b = statusItem.button {
            b.title = "J"
            b.toolTip = "JiraNotes"
        }
        menu = NSMenu()

        // About
        let aboutItem = NSMenuItem(title: "About JiraNotes",
                                   action: #selector(showAbout(_:)),
                                   keyEquivalent: "")
        aboutItem.target = self
        menu.addItem(aboutItem)
        
        
        // Separator
        menu.addItem(NSMenuItem.separator())
        
        // Status line (dynamic)
        let status = NSMenuItem(title: "Server: starting…", action: nil, keyEquivalent: "")
        status.tag = MenuTags.status
        status.isEnabled = false
        menu.addItem(status)

        // Port line (dynamic)
        let portItem = NSMenuItem(title: "Port: \(AppState.shared.port)", action: nil, keyEquivalent: "")
        portItem.tag = MenuTags.port
        portItem.isEnabled = false
        menu.addItem(portItem)
        
        // Server controls
        menu.addItem(NSMenuItem(title: "Restart Server", action: #selector(restartServer), keyEquivalent: ""))
        
        
        // Separator
        menu.addItem(NSMenuItem.separator())
        
        // Folder line (new)
        let folderLabel = NSMenuItem(title: "Folder: (not set)", action: nil, keyEquivalent: "")
        folderLabel.tag = MenuTags.folder
        folderLabel.isEnabled = false
        menu.addItem(folderLabel)
        
        // Folder controls
        menu.addItem(NSMenuItem(title: "Choose Notes Directory…", action: #selector(chooseDir), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Reveal Notes Folder", action: #selector(revealDir), keyEquivalent: ""))
        
        
        
        // Separator
        menu.addItem(NSMenuItem.separator())
        
        // Endpoints (static reference)
        let endpoints = NSMenuItem(title: "Endpoints…", action: #selector(showEndpoints), keyEquivalent: "")
        menu.addItem(endpoints)

        // Curl cheatsheet (copy)
        let cheats = NSMenuItem(title: "Copy curl cheatsheet", action: #selector(copyCurlCheatsheet), keyEquivalent: "")
        menu.addItem(cheats)

        // Diagnostics
        let diag = NSMenuItem(title: "Diagnostics…", action: #selector(showDiagnostics), keyEquivalent: "")
        menu.addItem(diag)

        

        
        // Separator
        menu.addItem(NSMenuItem.separator())

        // About & Quit
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q"))

        
        
        statusItem.menu = menu
    }

    func startServer() {
        let s = SimpleHTTPServer(port: AppState.shared.port)
        s.onRequest = { [weak self] req in
            guard let self = self else { return .notFound() }
            switch (req.method, req.path) {
            case ("GET","/ping"):
                return .okJSON(["ok": true])
            case ("POST","/choose"):
                DispatchQueue.main.async { self.chooseDir() }
                return .okJSON(["ok": true])
            case ("GET","/load"):
                guard let tid = req.query["ticketId"], let dir = AppState.shared.notesDir else {
                    return .okJSONText("{}")
                }
                let didStart = dir.startAccessingSecurityScopedResource()
                defer { if didStart { dir.stopAccessingSecurityScopedResource() } }

                let file = dir.appendingPathComponent("\(tid).json")
                if let data = try? Data(contentsOf: file),
                   let s = String(data: data, encoding: .utf8) {
                    return .okJSONText(s)
                }
                return .okJSONText("{}")
            case ("POST", "/save"):
                guard let tid = req.query["ticketId"],
                      let dir = AppState.shared.notesDir,
                      let body = req.bodyString else {
                    return .bad("missing params")
                }
                let didStart = dir.startAccessingSecurityScopedResource()
                defer { if didStart { dir.stopAccessingSecurityScopedResource() } }

                do {
                    // Ensure we handle symlinks (iCloud paths) & create the folder
                        let base = dir.resolvingSymlinksInPath()
                        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
                        let file = base.appendingPathComponent("\(tid).json")
                    
                    try Data(body.utf8).write(to: file, options: .atomic)
                    return .okJSON(["ok": true, "path": file.path])
                } catch {
                    return .bad("write failed: \(error.localizedDescription)")
                }
            case ("OPTIONS", _):
                // CORS preflight: no body needed
                return .init(status: "204 No Content",
                             headers: [("Content-Type","text/plain")],
                             body: Data())
            default:
                return .notFound()
            }
        }
        do { try s.start(); server = s;
            AppState.shared.running = true
            updateStatus("running on 127.0.0.1:18427")
            print("JiraNotes: server started on 127.0.0.1:18427")
        } catch {
            AppState.shared.running = false
            updateStatus("FAILED to start (\(error.localizedDescription))")
            print("JiraNotes: server failed to start: \(error)")
        }
    }

    @objc func chooseDir() {
        let p = NSOpenPanel()
        p.canChooseDirectories = true
        p.canChooseFiles = false
        p.allowsMultipleSelection = false
        if p.runModal() == .OK, let url = p.url {
            if Bookmark.store.save(url: url) {
                _ = url.startAccessingSecurityScopedResource()
                AppState.shared.notesDir = url
                updateStatus("folder set: \(url.lastPathComponent)")
                updateFolderMenu()   // refresh label
            }
        }
    }
    @objc func revealDir() { if let u = AppState.shared.notesDir { NSWorkspace.shared.activateFileViewerSelecting([u]) } }
    @objc func quit() { NSApp.terminate(nil) }

    @objc func diag() {
        let folder = AppState.shared.notesDir?.path ?? "(not set)"
        let alert = NSAlert()
        alert.messageText = "JiraNotes Diagnostics"
        alert.informativeText = "Folder: \(folder)\nServer: \(AppState.shared.running ? "running" : "stopped")"
        alert.runModal()
    }

    func updateStatus(_ text: String) {
        menu.item(withTag: MenuTags.status)?.title = "Server: \(text)"
        menu.item(withTag: MenuTags.port)?.title   = "Port: \(AppState.shared.port)"
    }
    
    @objc func showEndpoints() {
        let port = AppState.shared.port
        let text =
        """
        JiraNotes HTTP endpoints

        GET  /ping
          curl -i http://127.0.0.1:\(port)/ping

        GET  /load?ticketId=ABC-123
          curl -i "http://127.0.0.1:\(port)/load?ticketId=ABC-123"

        POST /save?ticketId=ABC-123
          curl -i -X POST "http://127.0.0.1:\(port)/save?ticketId=ABC-123" \\
            -H "Content-Type: application/json" \\
            --data '{"ticketId":"ABC-123","text":"Hello","updatedAt":"2025-01-01T00:00:00Z"}'

        POST /choose
          curl -i -X POST http://127.0.0.1:\(port)/choose
        """
        let a = NSAlert()
        a.messageText = "Endpoints"
        a.informativeText = text
        a.addButton(withTitle: "Copy")
        a.addButton(withTitle: "OK")
        let r = a.runModal()
        if r == .alertFirstButtonReturn { copyToClipboard(text) }
    }

    @objc func copyCurlCheatsheet() {
        let port = AppState.shared.port
        let text =
        """
        # Ping
        curl -i http://127.0.0.1:\(port)/ping

        # Save example
        curl -i -X POST "http://127.0.0.1:\(port)/save?ticketId=ABC-123" \\
          -H "Content-Type: application/json" \\
          --data '{"ticketId":"ABC-123","text":"Hello","updatedAt":"2025-01-01T00:00:00Z"}'

        # Load example
        curl -i "http://127.0.0.1:\(port)/load?ticketId=ABC-123"
        """
        copyToClipboard(text)
        let a = NSAlert()
        a.messageText = "Copied curl cheatsheet"
        a.informativeText = "Paste into Terminal and replace ABC-123 as needed."
        a.runModal()
    }

    @objc func showDiagnostics() {
        let folder = AppState.shared.notesDir?.path ?? "(not set)"
        let port = AppState.shared.port
        let running = AppState.shared.running ? "running" : "stopped"

        let a = NSAlert()
        a.messageText = "JiraNotes Diagnostics"
        a.informativeText =
        """
        Folder: \(folder)
        Server: \(running)
        Port:   \(port)

        Tips:
        • If Save fails in Safari, reload the page.
        • If preflight fails, ensure CORS/OPTIONS headers are enabled (already patched).
        • Re-choose the notes folder after renaming the app/bundle id.
        """
        a.addButton(withTitle: "Ping")
        a.addButton(withTitle: "OK")
        let r = a.runModal()
        if r == .alertFirstButtonReturn {
            // quick live ping
            let url = URL(string: "http://127.0.0.1:\(port)/ping")!
            var ok = false
            if let data = try? Data(contentsOf: url),
               let s = String(data: data, encoding: .utf8),
               s.contains("ok") { ok = true }
            let b = NSAlert()
            b.messageText = ok ? "Ping OK" : "Ping Failed"
            b.informativeText = ok ? "Server responded on 127.0.0.1:\(port)" : "No response"
            b.runModal()
        }
    }

    @objc func showAbout(_ sender: Any?) {
        NSApp.activate(ignoringOtherApps: true)

        let credits = NSAttributedString(string: """
    JiraNotes — lightweight notes for Jira issues.

    • Menu bar app writes one JSON per ticket.
    • Safari Web Extension injects the panel.

    © \(Calendar.current.component(.year, from: Date())) pmaklabs (Peter Mak)
    """)

        var info: [NSApplication.AboutPanelOptionKey: Any] = [
            .applicationName: "JiraNotes",
            .applicationVersion: "1.0.1",
            .version: "10",
            .credits: credits
        ]

        if let icon = NSApp.applicationIconImage {
            info[.applicationIcon] = icon
        }

        NSApp.orderFrontStandardAboutPanel(options: info)
    }

    @objc func restartServer() {
        updateStatus("restarting…")
        server?.stop()
        server = nil
        startServer()
    }
    
    // Update it whenever folder changes:
    func updateFolderMenu() {
        let name = AppState.shared.notesDir?.lastPathComponent ?? "(not set)"
        menu.item(withTag: 9003)?.title = "Folder: \(name)"
    }
}
