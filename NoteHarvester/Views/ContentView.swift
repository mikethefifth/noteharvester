//
//  ContentView.swift
//  NoteHarvester
//
//  Created by Lukas Selch on 25.09.24.
//

import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct ContentView: View {
    @State var books: [Book] = []
    @State var selectedBooks: Set<Book> = []
    @State var selectedAnnotations: Set<Annotation> = Set<Annotation>()
    @State private var isExportMenuPresented = false
    @State private var bookSearchText = ""
    @State private var annotationSearchText = ""
    
    private let databaseManager = DatabaseManager()
    @State private var keyboardMonitor: Any?
    
    var filteredBooks: [Book] {
        if bookSearchText.isEmpty {
            return books
        } else {
            return books.filter { book in
                book.title.lowercased().contains(bookSearchText.lowercased()) ||
                book.author.lowercased().contains(bookSearchText.lowercased())
            }
        }
    }

    var filteredAnnotations: [Annotation] {
        let selectedAnnotations = selectedBooks.flatMap { $0.annotations }
        if annotationSearchText.isEmpty {
            return selectedAnnotations
        } else {
            return selectedAnnotations.filter { annotation in
                annotation.quote?.lowercased().contains(annotationSearchText.lowercased()) ?? false ||
                annotation.comment?.lowercased().contains(annotationSearchText.lowercased()) ?? false
            }
        }
    }

    var body: some View {
        NavigationSplitView {
            List(filteredBooks, id: \.self, selection: $selectedBooks) { book in
                HStack {
                    if let coverURL = book.cover {
                        AsyncImage(url: coverURL) { image in
                            image
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .frame(width: 40, height: 60)
                        } placeholder: {
                            Image(systemName: "book.closed")
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .frame(width: 40, height: 60)
                                .foregroundColor(.secondary)
                        }
                    } else {
                        Image(systemName: "book.closed")
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(width: 40, height: 60)
                            .foregroundColor(.secondary)
                    }
                    
                    VStack(alignment: .leading) {
                        Text(book.author)
                            .font(.caption)
                        Text(book.title)
                            .font(.headline)
                        Text(book.annotations.count == 1 ? "1 Highlight" : "\(book.annotations.count) Highlights")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }
            .searchable(text: $bookSearchText, placement: .sidebar, prompt: "Search books")
            .onChange(of: bookSearchText) { _ in
                selectedAnnotations.removeAll()
            }
        } detail: {
            if selectedBooks.isEmpty {
                Text("Select one or more books to view annotations.")
            } else {
                let selectedAnnotations = selectedBooks.flatMap { $0.annotations }
                if selectedAnnotations.isEmpty {
                    Text("There are no annotations in the selected books.")
                        .font(.headline)
                        .foregroundColor(.gray)
                } else {
                    List(filteredAnnotations, id: \.self, selection: $selectedAnnotations) { annotation in
                        VStack(alignment: .leading) {
                            if let quote = annotation.quote {
                                if colorForCode(annotation.colorCode) == .clear {
                                    Text(quote)
                                        .font(.body)
                                        .underline(color: .red)
                                        .padding(.horizontal, 3)
                                } else {
                                    Text(quote)
                                        .font(.body)
                                        .background(
                                            colorForCode(annotation.colorCode)
                                                .opacity(0.3)
                                                .cornerRadius(3)
                                                .padding(.horizontal, -3)
                                        )
                                        .padding(.horizontal, 3)
                                }
                            }
                            if let comment = annotation.comment {
                                Text("- \(comment)")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                    .padding(.top, 2)
                                    .italic()
                            }
                        }
                        .padding(.vertical, 5)
                    }
                    .searchable(text: $annotationSearchText, placement: .toolbar, prompt: "Search annotations")
                    .contextMenu {
                        Button(action: {
                            copySelectedAnnotations()
                        }) {
                            Text("Copy Selection")
                            Image(systemName: "doc.on.doc")
                        }
                    }
                }
            }
        }
        .toolbar {
            ToolbarItem(placement: .automatic) {
                Button(action: {
                    isExportMenuPresented = true
                }) {
                    Label("Export", systemImage: "square.and.arrow.up")
                }
                .disabled(selectedAnnotations.isEmpty)
                .popover(isPresented: $isExportMenuPresented, arrowEdge: .bottom) {
                    VStack {
                        Button(action: {
                            exportAsCSV()
                            isExportMenuPresented = false
                        }) {
                            Label("Export as CSV", systemImage: "doc.plaintext")
                        }
                        .buttonStyle(.plain)
                        
                        Button(action: {
                            exportAsMarkdown()
                            isExportMenuPresented = false
                        }) {
                            Label("Export as Markdown", systemImage: "doc.text")
                        }
                        .buttonStyle(.plain)
                    }
                    .padding()
                }
            }
        }
        .onAppear {
            loadBooks()
            setupKeyboardShortcut()
        }
        .onDisappear {
            removeKeyboardShortcut()
        }
        .frame(minWidth: 600, minHeight: 400)
    }
    
    private func loadBooks() {
        do {
            var books = try databaseManager.getBooks()
            books.sort { $0.latestAnnotationDate <= $1.latestAnnotationDate }
            self.books = books
        } catch {
            print("Failed to load books: \(error)")
        }
    }
    
    private func colorForCode(_ code: Int64?) -> Color {
        switch code {
        case 0:
            return .clear
        case 1:
            return .green
        case 2:
            return .blue
        case 3:
            return .yellow
        case 4:
            return .pink
        case 5:
            return .purple
        default:
            return .primary
        }
    }
    
    private func copySelectedAnnotations() {
        let copiedText = selectedAnnotations.map { annotation in
            var text = ""
            if let quote = annotation.quote {
                text += "\"\(quote)\"\n"
            }
            if let comment = annotation.comment {
                text += "Note: \(comment)\n"
            }
            return text
        }.joined(separator: "\n")
        
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(copiedText, forType: .string)
    }
    
    private func setupKeyboardShortcut() {
        keyboardMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.modifierFlags.contains(.command) && event.keyCode == 8 { // 'C' key
                copySelectedAnnotations()
                return nil // Consumed the event
            }
            return event
        }
    }
    
    private func removeKeyboardShortcut() {
        if let monitor = keyboardMonitor {
            NSEvent.removeMonitor(monitor)
        }
    }
    
    private func exportAsCSV() {
        let csvString = "Author,Book Title,Quote,Comment\n" +
        selectedAnnotations.map { annotation in
            let book = books.first { $0.annotations.contains(annotation) }!
            return "\"\(book.author)\",\"\(book.title)\",\"\(annotation.quote ?? "")\",\"\(annotation.comment ?? "")\""
        }.joined(separator: "\n")
        
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType.commaSeparatedText]
        panel.nameFieldStringValue = "exported_annotations.csv"
        
        panel.begin { response in
            if response == .OK, let url = panel.url {
                do {
                    try csvString.write(to: url, atomically: true, encoding: .utf8)
                } catch {
                    print("Failed to save CSV: \(error)")
                }
            }
        }
    }
    
    private func exportAsMarkdown() {
        let markdownString = generateMarkdownContent()
        
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "md")].compactMap { $0 }
        panel.nameFieldStringValue = "exported_annotations.md"
        
        panel.begin { response in
            if response == .OK, let url = panel.url {
                do {
                    try markdownString.write(to: url, atomically: true, encoding: .utf8)
                } catch {
                    print("Failed to save Markdown: \(error)")
                }
            }
        }
    }
    
    private func generateMarkdownContent() -> String {
        // Group annotations by book
        let bookAnnotations = Dictionary(grouping: selectedAnnotations) { annotation in
            books.first { $0.annotations.contains(annotation) }!
        }
        
        var markdownContent = ""
        let exportDate = DateFormatter.localizedString(from: Date(), dateStyle: .medium, timeStyle: .none)
        
        // Handle multi-book vs single book export
        if bookAnnotations.count == 1 {
            // Single book export
            let book = bookAnnotations.keys.first!
            let annotations = bookAnnotations[book]!
            markdownContent = generateSingleBookMarkdown(book: book, annotations: annotations, exportDate: exportDate)
        } else {
            // Multi-book export
            markdownContent = generateMultiBookMarkdown(bookAnnotations: bookAnnotations, exportDate: exportDate)
        }
        
        return markdownContent
    }
    
    private func generateSingleBookMarkdown(book: Book, annotations: [Annotation], exportDate: String) -> String {
        var content = ""
        
        // Book title and metadata
        content += "# \(book.title)\n"
        content += "**by \(book.author)**\n\n"
        
        // Metadata section
        content += "## Metadata\n"
        content += "- **Author**: \(book.author)\n"
        content += "- **Export Date**: \(exportDate)\n"
        content += "- **Total Highlights**: \(annotations.filter { $0.quote != nil && !$0.quote!.isEmpty }.count)\n"
        content += "- **Total Notes**: \(annotations.filter { $0.comment != nil && !$0.comment!.isEmpty }.count)\n\n"
        
        // Group annotations by chapter if available
        let chapterGroups = Dictionary(grouping: annotations) { $0.chapter ?? "Unknown Chapter" }
        let sortedChapters = chapterGroups.keys.sorted()
        
        for chapter in sortedChapters {
            let chapterAnnotations = chapterGroups[chapter]!
            content += "## \(chapter)\n\n"
            
            for annotation in chapterAnnotations {
                content += formatAnnotation(annotation: annotation)
                content += "\n"
            }
        }
        
        return content
    }
    
    private func generateMultiBookMarkdown(bookAnnotations: [Book: [Annotation]], exportDate: String) -> String {
        var content = ""
        
        // Header for multi-book export
        content += "# Exported Annotations\n\n"
        content += "## Export Information\n"
        content += "- **Export Date**: \(exportDate)\n"
        content += "- **Books Included**: \(bookAnnotations.count)\n"
        
        let totalHighlights = bookAnnotations.values.flatMap { $0 }.filter { $0.quote != nil && !$0.quote!.isEmpty }.count
        let totalNotes = bookAnnotations.values.flatMap { $0 }.filter { $0.comment != nil && !$0.comment!.isEmpty }.count
        
        content += "- **Total Highlights**: \(totalHighlights)\n"
        content += "- **Total Notes**: \(totalNotes)\n\n"
        
        // Add each book
        let sortedBooks = bookAnnotations.keys.sorted { $0.title < $1.title }
        for book in sortedBooks {
            let annotations = bookAnnotations[book]!
            content += "---\n\n"
            content += generateSingleBookMarkdown(book: book, annotations: annotations, exportDate: exportDate)
        }
        
        return content
    }
    
    private func formatAnnotation(annotation: Annotation) -> String {
        var content = ""
        let isHighlight = annotation.quote != nil && !annotation.quote!.isEmpty
        let isNote = annotation.comment != nil && !annotation.comment!.isEmpty
        
        if isHighlight && isNote {
            // Both highlight and note
            content += "### Highlight with Note\n"
            content += "> \"\(annotation.quote!)\"\n\n"
            content += "**Personal Note:** \(annotation.comment!)\n\n"
        } else if isHighlight {
            // Just highlight
            content += "### Highlight\n"
            content += "> \"\(annotation.quote!)\"\n\n"
        } else if isNote {
            // Just note
            content += "### Note\n"
            content += "**Personal Note:** \(annotation.comment!)\n\n"
        }
        
        // Add metadata
        var metadata: [String] = []
        
        if let colorCode = annotation.colorCode {
            let colorName = colorNameForCode(colorCode)
            metadata.append("Color: \(colorName)")
        }
        
        if let createdAt = annotation.createdAt {
            let dateFormatter = DateFormatter()
            dateFormatter.dateStyle = .medium
            dateFormatter.timeStyle = .short
            let dateString = dateFormatter.string(from: Date(timeIntervalSince1970: createdAt))
            metadata.append("Created: \(dateString)")
        }
        
        if let modifiedAt = annotation.modifiedAt, modifiedAt != annotation.createdAt {
            let dateFormatter = DateFormatter()
            dateFormatter.dateStyle = .medium
            dateFormatter.timeStyle = .short
            let dateString = dateFormatter.string(from: Date(timeIntervalSince1970: modifiedAt))
            metadata.append("Modified: \(dateString)")
        }
        
        if !metadata.isEmpty {
            content += "*\(metadata.joined(separator: " • "))*\n"
        }
        
        return content
    }
    
    private func colorNameForCode(_ code: Int64) -> String {
        switch code {
        case 0:
            return "Underline"
        case 1:
            return "Green"
        case 2:
            return "Blue"
        case 3:
            return "Yellow"
        case 4:
            return "Pink"
        case 5:
            return "Purple"
        default:
            return "Default"
        }
    }
}

#Preview {
    ContentView()
}
