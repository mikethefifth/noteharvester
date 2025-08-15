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
    @State private var bookSearchText = ""
    @State private var loadingCancellationToken: Task<Void, Never>?
    @State private var sortBy: SortOption = .title
    @State private var viewMode: ViewMode = .grid
    @State private var showOnlyBooksWithAnnotations: Bool = true
    @State private var navigationPath = NavigationPath()
    
    @StateObject private var databaseManager = DatabaseManager()
    
    enum SortOption: String, CaseIterable {
        case title = "Title"
        case author = "Author"
        case latestAnnotation = "Latest Annotation"
        case annotationCount = "Annotation Count"
    }
    
    enum ViewMode: String, CaseIterable {
        case list = "List"
        case grid = "Grid"
        
        var icon: String {
            switch self {
            case .list: return "list.bullet"
            case .grid: return "square.grid.2x2"
            }
        }
    }
    
    var filteredBooks: [Book] {
        let searchFiltered = if bookSearchText.isEmpty {
            books
        } else {
            books.filter { book in
                book.title.lowercased().contains(bookSearchText.lowercased()) ||
                book.author.lowercased().contains(bookSearchText.lowercased())
            }
        }
        
        let annotationFiltered = if showOnlyBooksWithAnnotations {
            searchFiltered.filter { book in
                !book.annotations.isEmpty
            }
        } else {
            searchFiltered
        }
        
        return annotationFiltered.sorted { first, second in
            switch sortBy {
            case .title:
                return first.title.lowercased() < second.title.lowercased()
            case .author:
                return first.author.lowercased() < second.author.lowercased()
            case .latestAnnotation:
                return first.latestAnnotationDate >= second.latestAnnotationDate
            case .annotationCount:
                return first.annotations.count > second.annotations.count
            }
        }
    }
    
    var bookCountText: String {
        if showOnlyBooksWithAnnotations {
            return "\(filteredBooks.count) with highlights"
        } else {
            return "\(filteredBooks.count) books"
        }
    }

    @ViewBuilder
    private var mainContent: some View {
        if databaseManager.isLoading && books.isEmpty {
            loadingView
        } else if !databaseManager.isLoading && books.isEmpty && databaseManager.errorMessage != nil {
            errorView
        } else {
            booksMainView
        }
    }
    
    private var loadingView: some View {
        VStack(spacing: 20) {
            Image(systemName: "book.circle")
                .font(.system(size: 64))
                .foregroundColor(.secondary)
            
            Text("Loading Apple Books")
                .font(.title2)
                .fontWeight(.medium)
            
            ProgressView(value: databaseManager.loadingProgress)
                .progressViewStyle(LinearProgressViewStyle())
                .frame(maxWidth: 300)
            
            Text(databaseManager.loadingMessage)
                .font(.caption)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .animation(.easeInOut, value: databaseManager.loadingMessage)
            
            if let errorMessage = databaseManager.errorMessage {
                VStack(spacing: 10) {
                    Text(errorMessage)
                        .font(.caption)
                        .foregroundColor(.red)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                    
                    Button("Try Again") {
                        loadBooks()
                    }
                    .buttonStyle(.borderedProminent)
                }
                .padding(.top)
            }
            
            Button("Cancel") {
                cancelLoading()
            }
            .buttonStyle(.bordered)
        }
        .padding()
    }
    
    private var errorView: some View {
        VStack(spacing: 20) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 64))
                .foregroundColor(.orange)
            
            Text("Unable to Load Books")
                .font(.title2)
                .fontWeight(.medium)
            
            if let errorMessage = databaseManager.errorMessage {
                Text(errorMessage)
                    .font(.body)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
            }
            
            VStack(spacing: 10) {
                Button("Try Again") {
                    loadBooks()
                }
                .buttonStyle(.borderedProminent)
                
                Button("Open Apple Books") {
                    if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.iBooksX") {
                        NSWorkspace.shared.open(url)
                    }
                }
                .buttonStyle(.bordered)
            }
        }
        .padding()
    }
    
    private var booksMainView: some View {
        ScrollView {
            if viewMode == .grid {
                booksGridView
            } else {
                booksListContentView
            }
        }
        .background(Color.clear)
        .navigationTitle("Books")
        .searchable(text: $bookSearchText, placement: .toolbar, prompt: "Search your library...")
        .onChange(of: bookSearchText) { _ in
            // Clear selection when searching
        }
    }
    
    private var booksGridView: some View {
        // Use fixed columns for better performance during resize
        let columns = Array(repeating: GridItem(.flexible(), spacing: 20), count: 4)
        
        return LazyVGrid(columns: columns, spacing: 24) {
            ForEach(filteredBooks, id: \.id) { book in
                BookGridItem(book: book)
                    .id(book.id) // Stable identity for better performance
            }
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 40)
    }
    
    private var booksListContentView: some View {
        LazyVStack(spacing: 0) {
            ForEach(filteredBooks, id: \.self) { book in
                BookListItem(book: book)
            }
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 40)
    }
    

    var body: some View {
        NavigationStack(path: $navigationPath) {
            mainContent
                .navigationDestination(for: Book.self) { book in
                    BookDetailView(book: book)
                }
        }
        .toolbar {
            if navigationPath.isEmpty {
                ToolbarItem(placement: .primaryAction) {
                    HStack(spacing: 12) {
                        // Book count
                    Text(bookCountText)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .fixedSize()
                    
                    // View mode toggle
                    Picker(selection: $viewMode, label: EmptyView()) {
                        Image(systemName: ViewMode.list.icon)
                            .tag(ViewMode.list)
                        Image(systemName: ViewMode.grid.icon)
                            .tag(ViewMode.grid)
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 80)
                    
                    // Sort and filter menu
                    Menu {
                        // Sort options
                        ForEach(SortOption.allCases, id: \.self) { option in
                            Button(action: { sortBy = option }) {
                                HStack {
                                    Text(option.rawValue)
                                    Spacer()
                                    if sortBy == option {
                                        Image(systemName: "checkmark")
                                            .font(.system(size: 12, weight: .semibold))
                                    }
                                }
                            }
                        }
                        
                        Divider()
                        
                        // Filter option
                        Button(action: { showOnlyBooksWithAnnotations.toggle() }) {
                            HStack {
                                Text("Only Books with Highlights")
                                Spacer()
                                if showOnlyBooksWithAnnotations {
                                    Image(systemName: "checkmark")
                                        .font(.system(size: 12, weight: .semibold))
                                }
                            }
                        }
                    } label: {
                        Image(systemName: "arrow.up.arrow.down")
                    }
                    .menuStyle(.borderlessButton)
                    .help("Sort and filter books")
                }
                }
            
                ToolbarItem(placement: .automatic) {
                Button(action: {
                    books.removeAll()
                    loadBooks()
                }) {
                    Image(systemName: "arrow.clockwise")
                }
                .disabled(databaseManager.isLoading)
                .help("Refresh library")
                }
            }
        }
        .onAppear {
            loadBooks()
        }
        .onDisappear {
            cancelLoading()
        }
        .frame(minWidth: 900, idealWidth: 1200, minHeight: 600, idealHeight: 800)
        .navigationTitle("NoteHarvester")
    }
    
    private func loadBooks() {
        // Cancel any existing loading task
        loadingCancellationToken?.cancel()
        
        loadingCancellationToken = Task {
            for await result in databaseManager.loadBooksProgressively() {
                if Task.isCancelled { return }
                
                switch result {
                case .bookLoaded(let book):
                    await MainActor.run {
                        // Temporarily show ALL books to debug the issue
                        books.append(book)
                        print("📋 Loaded book: '\(book.title)' by \(book.author) - \(book.annotations.count) annotations")
                        // Sort books alphabetically as they come in
                        books.sort { $0.title.lowercased() < $1.title.lowercased() }
                    }
                    
                case .error(let error):
                    await MainActor.run {
                        print("Error loading book: \(error)")
                    }
                    
                case .completed(let totalBooksLoaded):
                    await MainActor.run {
                        print("Completed loading \(totalBooksLoaded) books")
                        // Final alphabetical sort
                        books.sort { $0.title.lowercased() < $1.title.lowercased() }
                    }
                }
            }
        }
    }
    
    private func cancelLoading() {
        loadingCancellationToken?.cancel()
        loadingCancellationToken = nil
    }
}

// MARK: - Book Item Components

struct BookGridItem: View {
    let book: Book
    
    var body: some View {
        NavigationLink(value: book) {
            VStack(alignment: .leading, spacing: 12) {
                // Book cover - simplified for performance
                ZStack {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color(NSColor.controlBackgroundColor))
                        .frame(height: 140)
                    
                    if let coverURL = book.cover {
                        AsyncImage(url: coverURL) { image in
                            image
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .cornerRadius(6)
                        } placeholder: {
                            Image(systemName: "book.closed")
                                .font(.system(size: 32, weight: .light))
                                .foregroundColor(.secondary.opacity(0.6))
                        }
                    } else {
                        Image(systemName: "book.closed")
                            .font(.system(size: 32, weight: .light))
                            .foregroundColor(.secondary.opacity(0.6))
                    }
                }
                .frame(height: 140)
                
                // Book info - clean typography
                VStack(alignment: .leading, spacing: 4) {
                    Text(book.title)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(.primary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    
                    Text(book.author)
                        .font(.system(size: 12, weight: .regular))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                    
                    Text("\(book.annotations.count) highlights")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.secondary)
                }
                
                Spacer()
            }
            .padding(12)
            .frame(height: 220)
            .background(Color(NSColor.controlBackgroundColor).opacity(0.5))
            .cornerRadius(12)
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(Color.primary.opacity(0.08), lineWidth: 1)
            )
            .shadow(color: Color.black.opacity(0.05), radius: 2, x: 0, y: 1)
        }
        .buttonStyle(.plain)
    }
}

struct BookListItem: View {
    let book: Book
    
    var body: some View {
        NavigationLink(value: book) {
            HStack(spacing: 12) {
                // Book cover - simplified
                if let coverURL = book.cover {
                    AsyncImage(url: coverURL) { image in
                        image
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(width: 32, height: 48)
                            .cornerRadius(4)
                    } placeholder: {
                        Image(systemName: "book.closed")
                            .font(.system(size: 16, weight: .light))
                            .foregroundColor(.secondary.opacity(0.6))
                            .frame(width: 32, height: 48)
                    }
                } else {
                    Image(systemName: "book.closed")
                        .font(.system(size: 16, weight: .light))
                        .foregroundColor(.secondary.opacity(0.6))
                        .frame(width: 32, height: 48)
                }
                
                // Book info - optimized
                VStack(alignment: .leading, spacing: 2) {
                    Text(book.title)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(.primary)
                        .lineLimit(1)
                    
                    Text(book.author)
                        .font(.system(size: 12, weight: .regular))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                    
                    Text("\(book.annotations.count) highlights")
                        .font(.system(size: 11, weight: .regular))
                        .foregroundColor(.secondary)
                }
                
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Book Detail View

struct BookDetailView: View {
    let book: Book
    @State private var selectedAnnotations: Set<Annotation> = Set<Annotation>()
    @State private var annotationSearchText = ""
    @State private var viewMode: AnnotationViewMode = .list
    
    enum AnnotationViewMode: String, CaseIterable {
        case list = "List"
        case grid = "Cards"
        
        var icon: String {
            switch self {
            case .list: return "list.bullet"
            case .grid: return "rectangle.grid.2x2"
            }
        }
    }
    
    var filteredAnnotations: [Annotation] {
        if annotationSearchText.isEmpty {
            return book.annotations
        } else {
            return book.annotations.filter { annotation in
                annotation.quote?.lowercased().contains(annotationSearchText.lowercased()) ?? false ||
                annotation.comment?.lowercased().contains(annotationSearchText.lowercased()) ?? false
            }
        }
    }
    
    var body: some View {
        VStack(spacing: 0) {
            // Modern header with clean styling
            HStack(spacing: 20) {
                // Book cover - larger and more prominent
                if let coverURL = book.cover {
                    AsyncImage(url: coverURL) { image in
                        image
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(width: 60, height: 90)
                            .cornerRadius(8)
                    } placeholder: {
                        Image(systemName: "book.closed")
                            .font(.system(size: 24, weight: .light))
                            .foregroundColor(.secondary.opacity(0.6))
                            .frame(width: 60, height: 90)
                            .background(Color(NSColor.controlBackgroundColor))
                            .cornerRadius(8)
                    }
                } else {
                    Image(systemName: "book.closed")
                        .font(.system(size: 24, weight: .light))
                        .foregroundColor(.secondary.opacity(0.6))
                        .frame(width: 60, height: 90)
                        .background(Color(NSColor.controlBackgroundColor))
                        .cornerRadius(8)
                }
                
                // Book info with clean typography
                VStack(alignment: .leading, spacing: 6) {
                    Text(book.title)
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundColor(.primary)
                        .lineLimit(2)
                    
                    Text(book.author)
                        .font(.system(size: 16, weight: .regular))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                    
                    Text("\(book.annotations.count) highlights")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(.secondary)
                }
                
                Spacer()
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
            .background(Color.clear)
            
            // Annotations content
            if filteredAnnotations.isEmpty {
                VStack(spacing: 16) {
                    Image(systemName: "highlighter")
                        .font(.system(size: 48))
                        .foregroundColor(.secondary)
                    
                    Text(annotationSearchText.isEmpty ? "No highlights in this book" : "No highlights match your search")
                        .font(.headline)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    if viewMode == .grid {
                        annotationsGridView
                            .padding(.horizontal, 24)
                            .padding(.bottom, 40)
                    } else {
                        LazyVStack(spacing: 0) {
                            annotationsListView
                        }
                        .padding(.horizontal, 24)
                        .padding(.bottom, 40)
                    }
                }
            }
        }
        .background(Color.clear)
        .navigationTitle(book.title)
        .searchable(text: $annotationSearchText, placement: .toolbar, prompt: "Search highlights...")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                HStack(spacing: 12) {
                    // Annotation count
                    Text("\(filteredAnnotations.count) highlights")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .fixedSize()
                    
                    // View mode toggle for annotations
                    Picker(selection: $viewMode, label: EmptyView()) {
                        Image(systemName: AnnotationViewMode.list.icon)
                            .tag(AnnotationViewMode.list)
                        Image(systemName: AnnotationViewMode.grid.icon)
                            .tag(AnnotationViewMode.grid)
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 80)
                    
                    // Export menu
                    Menu {
                        Button(action: {
                            exportAsCSV()
                        }) {
                            Label("Export as CSV", systemImage: "doc.plaintext")
                        }
                        
                        Button(action: {
                            exportAsMarkdown()
                        }) {
                            Label("Export as Markdown", systemImage: "doc.text")
                        }
                    } label: {
                        Image(systemName: "square.and.arrow.up")
                    }
                    .disabled(book.annotations.isEmpty)
                    .menuStyle(.borderlessButton)
                    .help("Export highlights")
                }
            }
        }
    }
    
    private func copySelectedAnnotations() {
        let annotations = selectedAnnotations.isEmpty ? [filteredAnnotations.first].compactMap { $0 } : Array(selectedAnnotations)
        let copiedText = annotations.map { annotation in
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
    
    private func exportAsCSV() {
        let csvString = "Author,Book Title,Quote,Comment\n" +
        book.annotations.map { annotation in
            return "\"\(book.author)\",\"\(book.title)\",\"\(annotation.quote ?? "")\",\"\(annotation.comment ?? "")\""
        }.joined(separator: "\n")
        
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType.commaSeparatedText]
        panel.nameFieldStringValue = "\(book.title)_annotations.csv"
        
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
        // Use existing markdown generation logic but for single book
        let markdownContent = generateSingleBookMarkdown(book: book, annotations: book.annotations)
        
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "md")].compactMap { $0 }
        panel.nameFieldStringValue = "\(book.title)_annotations.md"
        
        panel.begin { response in
            if response == .OK, let url = panel.url {
                do {
                    try markdownContent.write(to: url, atomically: true, encoding: .utf8)
                } catch {
                    print("Failed to save Markdown: \(error)")
                }
            }
        }
    }
    
    private func generateSingleBookMarkdown(book: Book, annotations: [Annotation]) -> String {
        var content = ""
        let exportDate = DateFormatter.localizedString(from: Date(), dateStyle: .medium, timeStyle: .none)
        
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
        
        return content
    }
    
    // List view for annotations
    private var annotationsListView: some View {
        LazyVStack(spacing: 12) {
            ForEach(filteredAnnotations, id: \.self) { annotation in
                AnnotationListItem(annotation: annotation)
            }
        }
    }
    
    // Grid view for annotations (Scrivener-style cards)
    private var annotationsGridView: some View {
        let columns = Array(repeating: GridItem(.flexible(), spacing: 16), count: 3)
        return LazyVGrid(columns: columns, spacing: 20) {
            ForEach(filteredAnnotations, id: \.self) { annotation in
                AnnotationCard(annotation: annotation)
            }
        }
    }
}

// MARK: - Annotation Components

struct AnnotationListItem: View {
    let annotation: Annotation
    
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            // Color indicator
            Circle()
                .fill(colorForCode(annotation.colorCode))
                .frame(width: 8, height: 8)
                .padding(.top, 6)
            
            VStack(alignment: .leading, spacing: 8) {
                if let quote = annotation.quote {
                    Text(quote)
                        .font(.system(size: 15, weight: .regular, design: .serif))
                        .foregroundColor(.primary)
                        .multilineTextAlignment(.leading)
                }
                if let comment = annotation.comment {
                    Text(comment)
                        .font(.system(size: 13, weight: .regular))
                        .foregroundColor(.secondary)
                        .italic()
                        .multilineTextAlignment(.leading)
                }
            }
            
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Color(NSColor.controlBackgroundColor).opacity(0.3))
        .cornerRadius(8)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.primary.opacity(0.05), lineWidth: 1)
        )
    }
    
    private func colorForCode(_ code: Int64?) -> Color {
        switch code {
        case 0: return .red
        case 1: return .green
        case 2: return .blue
        case 3: return .yellow
        case 4: return .pink
        case 5: return .purple
        default: return .orange
        }
    }
}

// Scrivener-style whimsical cards
struct AnnotationCard: View {
    let annotation: Annotation
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Card header with color accent
            HStack {
                Circle()
                    .fill(colorForCode(annotation.colorCode))
                    .frame(width: 12, height: 12)
                
                Spacer()
                
                Text(cardTypeText)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.secondary)
                    .textCase(.uppercase)
                    .tracking(0.5)
            }
            
            // Quote content
            if let quote = annotation.quote {
                Text(quote)
                    .font(.system(size: 14, weight: .regular, design: .serif))
                    .foregroundColor(.primary)
                    .multilineTextAlignment(.leading)
                    .lineLimit(6)
            }
            
            // Comment if exists
            if let comment = annotation.comment {
                Divider()
                    .padding(.vertical, 4)
                
                Text(comment)
                    .font(.system(size: 12, weight: .regular))
                    .foregroundColor(.secondary)
                    .italic()
                    .multilineTextAlignment(.leading)
                    .lineLimit(3)
            }
            
            Spacer()
        }
        .padding(16)
        .frame(height: 180)
        .background(cardBackgroundColor.opacity(0.1))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(colorForCode(annotation.colorCode).opacity(0.3), lineWidth: 2)
        )
        .cornerRadius(12)
        .shadow(color: colorForCode(annotation.colorCode).opacity(0.1), radius: 4, x: 0, y: 2)
        .scaleEffect(0.98)
        .animation(.easeInOut(duration: 0.2), value: annotation.id)
    }
    
    private var cardTypeText: String {
        if annotation.quote != nil && annotation.comment != nil {
            return "Highlight + Note"
        } else if annotation.quote != nil {
            return "Highlight"
        } else {
            return "Note"
        }
    }
    
    private var cardBackgroundColor: Color {
        colorForCode(annotation.colorCode)
    }
    
    private func colorForCode(_ code: Int64?) -> Color {
        switch code {
        case 0: return .red
        case 1: return .green
        case 2: return .blue
        case 3: return .yellow
        case 4: return .pink
        case 5: return .purple
        default: return .orange
        }
    }
}

// Legacy annotation row for compatibility
struct AnnotationRow: View {
    let annotation: Annotation
    
    var body: some View {
        AnnotationListItem(annotation: annotation)
    }
}


#Preview {
    ContentView()
}