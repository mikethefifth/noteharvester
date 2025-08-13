//
//  DatabaseManager.swift
//  NoteHarvester
//
//  Created by Lukas Selch on 25.09.24.
//

import Foundation
import SQLite
// Note: EPUBKit temporarily disabled due to repository availability
// import EPUBKit

@MainActor
class DatabaseManager: ObservableObject {
    private let APPLE_EPOCH_START: TimeInterval = 978307200 // 2001-01-01
    
    private let ANNOTATION_DB_PATH = "/users/\(NSUserName())/Library/Containers/com.apple.iBooksX/Data/Documents/AEAnnotation/"
    private let BOOK_DB_PATH = "/users/\(NSUserName())/Library/Containers/com.apple.iBooksX/Data/Documents/BKLibrary/"
    
    @Published var isLoading = false
    @Published var loadingProgress: Double = 0.0
    @Published var loadingMessage = ""
    @Published var errorMessage: String?
    
    // Simple cache to avoid reprocessing books
    private var loadedBooks: [String: Book] = [:]
    private var lastLoadTime: Date?
    
    private let SELECT_ALL_ANNOTATIONS_QUERY = """
    SELECT 
      ZANNOTATIONASSETID as assetId,
      ZANNOTATIONSELECTEDTEXT as quote,
      ZANNOTATIONNOTE as comment,
      ZFUTUREPROOFING5 as chapter,
      ZANNOTATIONSTYLE as colorCode,
      ZANNOTATIONMODIFICATIONDATE as modifiedAt,
      ZANNOTATIONCREATIONDATE as createdAt
    FROM ZAEANNOTATION
    WHERE ZANNOTATIONDELETED = 0 
      AND ZANNOTATIONSELECTEDTEXT IS NOT NULL 
      AND ZANNOTATIONSELECTEDTEXT <> ''
    ORDER BY ZANNOTATIONASSETID, ZPLLOCATIONRANGESTART;
    """
    
    private let SELECT_ALL_BOOKS_QUERY = """
    SELECT ZASSETID as id, ZTITLE as title, ZAUTHOR as author, ZPATH as path FROM ZBKLIBRARYASSET;
    """
    
    // Check if Apple Books database is available
    private func validateAppleBooksAccess() throws {
        guard FileManager.default.fileExists(atPath: BOOK_DB_PATH) else {
            throw DatabaseError.appleBooksNotFound
        }
        
        guard FileManager.default.fileExists(atPath: ANNOTATION_DB_PATH) else {
            throw DatabaseError.annotationsNotFound
        }
        
        // Try to read the directories to ensure we have permission
        _ = try FileManager.default.contentsOfDirectory(atPath: BOOK_DB_PATH)
        _ = try FileManager.default.contentsOfDirectory(atPath: ANNOTATION_DB_PATH)
    }
    
    func getBooks() throws -> [Book] {
        let booksFiles = try FileManager.default.contentsOfDirectory(atPath: BOOK_DB_PATH).filter { $0.hasSuffix(".sqlite") }
        var books: [Book] = []
        
        for file in booksFiles {
            let db = try Connection("\(BOOK_DB_PATH)/\(file)")
            let stmt = try db.prepare(SELECT_ALL_BOOKS_QUERY)
            for row in stmt {
                let id = row[0] as! String
                let title = row[1] as! String
                let author = row[2] as! String
                guard let coverPathString = row[3] as? String else {
                    continue
                }
                let cover = parseCoverImage(bookPathString: coverPathString)
                
                let annotations = try getAnnotations(forBookId: id)
                books.append(Book(id: id, title: title, author: author, cover: cover, annotations: annotations))
            }
        }
        
        return books
    }
    
    // New async method for progressive loading
    func loadBooksProgressively() -> AsyncStream<BookLoadingResult> {
        AsyncStream { continuation in
            Task {
                await MainActor.run {
                    isLoading = true
                    loadingProgress = 0.0
                    loadingMessage = "Scanning Apple Books database..."
                    errorMessage = nil
                }
                
                do {
                    // Validate Apple Books access first
                    try validateAppleBooksAccess()
                    
                    let booksFiles = try FileManager.default.contentsOfDirectory(atPath: BOOK_DB_PATH).filter { $0.hasSuffix(".sqlite") }
                    
                    guard !booksFiles.isEmpty else {
                        await MainActor.run {
                            errorMessage = "No Apple Books database files found. Please ensure you have books in Apple Books."
                            isLoading = false
                        }
                        continuation.finish()
                        return
                    }
                    
                    let totalFiles = booksFiles.count
                    
                    await MainActor.run {
                        loadingMessage = "Found \(totalFiles) database files"
                    }
                    
                    var processedFiles = 0
                    var totalBooksProcessed = 0
                    
                    for (fileIndex, file) in booksFiles.enumerated() {
                        do {
                            let db = try Connection("\(BOOK_DB_PATH)/\(file)")
                            let stmt = try db.prepare(SELECT_ALL_BOOKS_QUERY)
                            
                            for row in stmt {
                                let id = row[0] as! String
                                let title = row[1] as! String
                                let author = row[2] as! String
                                guard let coverPathString = row[3] as? String else {
                                    continue
                                }
                                
                                // Skip if we already loaded this book recently
                                if let cachedBook = loadedBooks[id],
                                   let lastLoad = lastLoadTime,
                                   Date().timeIntervalSince(lastLoad) < 300 { // 5 minutes cache
                                    continuation.yield(.bookLoaded(cachedBook))
                                    totalBooksProcessed += 1
                                    continue
                                }
                                
                                await MainActor.run {
                                    loadingMessage = "Loading '\(title)' by \(author)"
                                }
                                
                                // Process cover and annotations in background
                                let (cover, annotations) = await withTaskGroup(of: (URL?, [Annotation]).self) { group in
                                    group.addTask {
                                        let cover = self.parseCoverImage(bookPathString: coverPathString)
                                        let annotations = try? self.getAnnotations(forBookId: id)
                                        return (cover, annotations ?? [])
                                    }
                                    
                                    return await group.next() ?? (nil, [])
                                }
                                
                                let book = Book(id: id, title: title, author: author, cover: cover, annotations: annotations)
                                
                                // Cache the book
                                await MainActor.run {
                                    loadedBooks[id] = book
                                }
                                
                                totalBooksProcessed += 1
                                
                                await MainActor.run {
                                    loadingProgress = Double(fileIndex + 1) / Double(totalFiles)
                                }
                                
                                continuation.yield(.bookLoaded(book))
                            }
                        } catch {
                            await MainActor.run {
                                loadingMessage = "Error loading file \(file): \(error.localizedDescription)"
                            }
                            continuation.yield(.error(error))
                        }
                        
                        processedFiles += 1
                    }
                    
                    await MainActor.run {
                        loadingProgress = 1.0
                        loadingMessage = "Loaded \(totalBooksProcessed) books successfully"
                        isLoading = false
                        lastLoadTime = Date()
                    }
                    
                    continuation.yield(.completed(totalBooksProcessed))
                    continuation.finish()
                    
                } catch {
                    await MainActor.run {
                        errorMessage = error.localizedDescription
                        isLoading = false
                    }
                    continuation.yield(.error(error))
                    continuation.finish()
                }
            }
        }
    }
    
    // Method to clear cache and force reload
    func clearCache() {
        loadedBooks.removeAll()
        lastLoadTime = nil
    }
    
    private func getAnnotations(forBookId bookId: String) throws -> [Annotation] {
        let annotationsFiles = try FileManager.default.contentsOfDirectory(atPath: ANNOTATION_DB_PATH).filter { $0.hasSuffix(".sqlite") }
        var annotations: [Annotation] = []
        
        for file in annotationsFiles {
            let db = try Connection("\(ANNOTATION_DB_PATH)/\(file)")
            let stmt = try db.prepare(SELECT_ALL_ANNOTATIONS_QUERY)
            for row in stmt {
                if row[0] as! String == bookId {
                    if let assetId = row[0] as? String {
                        annotations.append(Annotation(
                            assetId: assetId,
                            quote: row[1] as? String,
                            comment: row[2] as? String,
                            chapter: row[3] as? String,
                            colorCode: row[4] as? Int64,
                            modifiedAt: (row[5] as? Int).flatMap { convertAppleTime($0) },
                            createdAt: (row[6] as? Int).flatMap { convertAppleTime($0) }
                        ))
                    }
                }
            }
        }
        
        return annotations
    }
    
    private func convertAppleTime(_ appleTime: Int) -> TimeInterval {
        return APPLE_EPOCH_START + TimeInterval(appleTime)
    }
    
    private func parseCoverImage(bookPathString: String) -> URL? {
        // Note: EPUBKit temporarily disabled due to repository availability
        // TODO: Implement alternative EPUB cover parsing or find working EPUBKit alternative
        // guard let document = EPUBDocument(url: URL(fileURLWithPath: bookPathString)) else { return nil }
        // return document.cover
        return nil  // Temporarily return nil until EPUBKit dependency is resolved
    }
    
    func exportAnnotationsToCSV(annotations: [Annotation], fileName: String) throws {
        let csvString = annotations.map { annotation in
            return "\(annotation.assetId),\(annotation.quote ?? ""),\(annotation.comment ?? ""),\(annotation.chapter ?? ""),\(annotation.modifiedAt ?? 0),\(annotation.createdAt ?? 0)"
        }.joined(separator: "\n")
        
        let fileURL = FileManager.default.temporaryDirectory.appendingPathComponent(fileName)
        try csvString.write(to: fileURL, atomically: true, encoding: .utf8)
        print("Annotations exported to: \(fileURL.path)")
    }
}

enum DatabaseError: LocalizedError {
    case appleBooksNotFound
    case annotationsNotFound
    
    var errorDescription: String? {
        switch self {
        case .appleBooksNotFound:
            return "Apple Books library not found. Please ensure Apple Books is installed and you have books in your library."
        case .annotationsNotFound:
            return "Apple Books annotations database not found. This may be due to privacy settings or Apple Books not being properly configured."
        }
    }
}

enum BookLoadingResult {
    case bookLoaded(Book)
    case error(Error)
    case completed(Int)
}

struct Book: Hashable {
    let id: String
    let title: String
    let author: String
    let cover: URL?
    let annotations: [Annotation]
    
    var latestAnnotationDate: TimeInterval {
        annotations.map { $0.modifiedAt ?? $0.createdAt ?? 0 }.max() ?? 0
    }
}

struct Annotation: Hashable {
    let id: UUID = UUID()
    let assetId: String
    let quote: String?
    let comment: String?
    let chapter: String?
    let colorCode: Int64?
    let modifiedAt: TimeInterval?
    let createdAt: TimeInterval?
}
