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

extension String {
    func appendToURL(fileURL: URL) throws {
        if !FileManager.default.fileExists(atPath: fileURL.path) {
            try self.write(to: fileURL, atomically: true, encoding: .utf8)
        } else {
            let fileHandle = try FileHandle(forWritingTo: fileURL)
            fileHandle.seekToEndOfFile()
            if let data = self.data(using: .utf8) {
                fileHandle.write(data)
            }
            fileHandle.closeFile()
        }
    }
}

@MainActor
class DatabaseManager: ObservableObject {
    private let APPLE_EPOCH_START: TimeInterval = 978307200 // 2001-01-01
    
    private let ANNOTATION_DB_PATH = "/users/\(NSUserName())/Library/Containers/com.apple.iBooksX/Data/Documents/AEAnnotation/"
    private let BOOK_DB_PATH = "/users/\(NSUserName())/Library/Containers/com.apple.iBooksX/Data/Documents/BKLibrary/"
    private let CLOUD_DATA_DB_PATH = "/users/\(NSUserName())/Library/Containers/com.apple.iBooksX/Data/Documents/BCCloudData-iBooks/"
    
    // Cache management
    private let cacheURL: URL
    private let lastUpdateKey = "NoteHarvester_LastDatabaseUpdate"
    
    @Published var isLoading = false
    @Published var loadingProgress: Double = 0.0
    @Published var loadingMessage = ""
    @Published var errorMessage: String?
    
    // Simple cache to avoid reprocessing books
    private var loadedBooks: [String: Book] = [:]
    private var lastLoadTime: Date?
    
    init() {
        // Set up persistent cache location
        let cacheDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        cacheURL = cacheDir.appendingPathComponent("NoteHarvester").appendingPathComponent("books_cache.json")
    }
    
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
    ORDER BY ZANNOTATIONASSETID, ZPLLOCATIONRANGESTART;
    """
    
    private let SELECT_ALL_BOOKS_QUERY = """
    SELECT ZASSETID as id, ZTITLE as title, ZAUTHOR as author, ZPATH as path, ZCOVERURL as coverURL FROM ZBKLIBRARYASSET;
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
                let coverPathString = row[3] as? String
                let coverURLString = row[4] as? String
                
                // Try cover URL first, then fall back to parsing from file path
                let cover = getCoverImage(coverURL: coverURLString, bookPath: coverPathString)
                
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
                    // Check if we can use cached data
                    if !shouldRefreshCache(), let cachedBooks = loadBooksFromCache() {
                        await MainActor.run {
                            loadingMessage = "Loading from cache..."
                            loadingProgress = 0.5
                        }
                        
                        // Yield cached books
                        for book in cachedBooks {
                            continuation.yield(.bookLoaded(book))
                        }
                        
                        await MainActor.run {
                            loadingProgress = 1.0
                            loadingMessage = "Loaded \(cachedBooks.count) books from cache"
                            isLoading = false
                            lastLoadTime = Date()
                        }
                        
                        continuation.yield(.completed(cachedBooks.count))
                        continuation.finish()
                        return
                    }
                    
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
                    var allLoadedBooks: [Book] = []
                    
                    for (fileIndex, file) in booksFiles.enumerated() {
                        do {
                            let db = try Connection("\(BOOK_DB_PATH)/\(file)")
                            let stmt = try db.prepare(SELECT_ALL_BOOKS_QUERY)
                            
                            for row in stmt {
                                let id = row[0] as! String
                                let title = row[1] as! String
                                let author = row[2] as! String
                                let coverPathString = row[3] as? String
                                let coverURLString = row[4] as? String
                                
                                print("🔎 Processing book: '\(title)' by \(author) (ID: \(id))")
                                
                                // Write debug info to a file we can examine
                                let debugInfo = "🔎 Processing book: '\(title)' by \(author) (ID: \(id))\n"
                                if let documentsDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
                                    let debugURL = documentsDir.appendingPathComponent("noteharvester_debug.txt")
                                    try? debugInfo.appendToURL(fileURL: debugURL)
                                }
                                
                                // Special debug for the specific book we're looking for
                                if title.contains("Escaping") && title.contains("Build") && title.contains("Trap") {
                                    print("🎯 FOUND TARGET BOOK: '\(title)' by \(author) (ID: \(id))")
                                    let targetDebug = "🎯 FOUND TARGET BOOK: '\(title)' by \(author) (ID: \(id))\n"
                                    if let documentsDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
                                        let debugURL = documentsDir.appendingPathComponent("noteharvester_debug.txt")
                                        try? targetDebug.appendToURL(fileURL: debugURL)
                                    }
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
                                
                                // Process cover and annotations  
                                let cover = getCoverImage(coverURL: coverURLString, bookPath: coverPathString)
                                let annotations = try getAnnotations(forBookId: id)
                                
                                // Debug: Log books with annotations
                                if !annotations.isEmpty {
                                    print("📚 Found \(annotations.count) annotations in '\(title)' by \(author)")
                                } else {
                                    print("📖 No annotations found in '\(title)' by \(author)")
                                }
                                
                                let book = Book(id: id, title: title, author: author, cover: cover, annotations: annotations)
                                
                                // Cache the book
                                await MainActor.run {
                                    loadedBooks[id] = book
                                }
                                
                                totalBooksProcessed += 1
                                allLoadedBooks.append(book)
                                
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
                    
                    // Save to cache
                    saveBooksToCache(allLoadedBooks)
                    
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
        clearPersistentCache()
    }
    
    // MARK: - Persistent Cache Management
    
    private func saveBooksToCache(_ books: [Book]) {
        do {
            // Create cache directory if needed
            try FileManager.default.createDirectory(at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            
            let data = try JSONEncoder().encode(books)
            try data.write(to: cacheURL)
            
            // Store last update time
            UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: lastUpdateKey)
            
            print("📦 Saved \(books.count) books to cache")
        } catch {
            print("❌ Failed to save cache: \(error)")
        }
    }
    
    private func loadBooksFromCache() -> [Book]? {
        guard FileManager.default.fileExists(atPath: cacheURL.path) else {
            print("📦 No cache file found")
            return nil
        }
        
        do {
            let data = try Data(contentsOf: cacheURL)
            let books = try JSONDecoder().decode([Book].self, from: data)
            print("📦 Loaded \(books.count) books from cache")
            return books
        } catch {
            print("❌ Failed to load cache: \(error)")
            return nil
        }
    }
    
    private func clearPersistentCache() {
        try? FileManager.default.removeItem(at: cacheURL)
        UserDefaults.standard.removeObject(forKey: lastUpdateKey)
        print("📦 Cleared persistent cache")
    }
    
    private func shouldRefreshCache() -> Bool {
        guard let lastUpdate = UserDefaults.standard.object(forKey: lastUpdateKey) as? TimeInterval else {
            print("📦 No cache timestamp - needs refresh")
            return true
        }
        
        let timeSinceUpdate = Date().timeIntervalSince1970 - lastUpdate
        let shouldRefresh = timeSinceUpdate > 3600 // Refresh after 1 hour
        
        if shouldRefresh {
            print("📦 Cache is \(Int(timeSinceUpdate/60)) minutes old - needs refresh")
        } else {
            print("📦 Cache is \(Int(timeSinceUpdate/60)) minutes old - still fresh")
        }
        
        return shouldRefresh
    }
    
    // Force refresh from database (ignores cache)
    func refreshFromDatabase() {
        clearPersistentCache()
    }
    
    private func getAnnotations(forBookId bookId: String) throws -> [Annotation] {
        var annotations: [Annotation] = []
        
        // Get annotations from local AEAnnotation database
        let annotationsFiles = try FileManager.default.contentsOfDirectory(atPath: ANNOTATION_DB_PATH).filter { $0.hasSuffix(".sqlite") }
        
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
        
        // Get additional annotations from BCCloudData
        let cloudAnnotations = try getCloudAnnotations(forBookId: bookId)
        print("🔮 Found \(cloudAnnotations.count) cloud annotations for book \(bookId)")
        annotations.append(contentsOf: cloudAnnotations)
        
        return annotations
    }
    
    private func getCloudAnnotations(forBookId bookId: String) throws -> [Annotation] {
        var annotations: [Annotation] = []
        
        let cloudDataPath = "\(CLOUD_DATA_DB_PATH)BCAssetData/BCAssetData"
        
        guard FileManager.default.fileExists(atPath: cloudDataPath) else {
            // Cloud data not available, return empty array
            return annotations
        }
        
        do {
            let db = try Connection(cloudDataPath)
            let query = "SELECT ZBOOKANNOTATIONS FROM ZBCASSETANNOTATIONS WHERE ZASSETID = ? AND ZDELETEDFLAG = 0 AND ZBOOKANNOTATIONS IS NOT NULL"
            let stmt = try db.prepare(query)
            
            print("🔍 Querying cloud database for book \(bookId)")
            
            for row in try stmt.run([bookId]) {
                if let blobData = row[0] as? Blob {
                    let data = Data(blobData.bytes)
                    print("🔍 Found cloud BLOB data of \(data.count) bytes")
                    let decodedAnnotations = try decodeAnnotationsBlob(data, assetId: bookId)
                    print("🔍 Decoded \(decodedAnnotations.count) annotations from BLOB")
                    annotations.append(contentsOf: decodedAnnotations)
                }
            }
        } catch {
            print("Warning: Could not read cloud annotations for \(bookId): \(error)")
        }
        
        return annotations
    }
    
    private func decodeAnnotationsBlob(_ data: Data, assetId: String) throws -> [Annotation] {
        var annotations: [Annotation] = []
        
        do {
            // Try to decode as Property List first
            if let plist = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] {
                annotations.append(contentsOf: parseAnnotationsFromPlist(plist, assetId: assetId))
            }
        } catch {
            // If plist fails, try other decoding methods
            print("Could not decode annotations BLOB as plist: \(error)")
            
            // Try to decode as archived NSData
            do {
                if #available(macOS 10.13, *) {
                    let unarchiver = try NSKeyedUnarchiver(forReadingFrom: data)
                    unarchiver.requiresSecureCoding = false
                    if let archived = try unarchiver.decodeTopLevelObject() {
                        annotations.append(contentsOf: parseAnnotationsFromArchived(archived, assetId: assetId))
                    }
                }
            } catch {
                print("Could not decode annotations BLOB as archived data: \(error)")
            }
        }
        
        return annotations
    }
    
    private func parseAnnotationsFromPlist(_ plist: [String: Any], assetId: String) -> [Annotation] {
        var annotations: [Annotation] = []
        
        // This is a best-guess implementation based on typical Apple Books data structure
        if let annotationsArray = plist["annotations"] as? [[String: Any]] {
            for annotationDict in annotationsArray {
                let quote = annotationDict["selectedText"] as? String
                let comment = annotationDict["note"] as? String
                let chapter = annotationDict["chapter"] as? String
                let colorCode = annotationDict["style"] as? Int64
                
                // Convert timestamps if present
                let modifiedAt: TimeInterval?
                let createdAt: TimeInterval?
                
                if let modTime = annotationDict["modificationDate"] as? TimeInterval {
                    modifiedAt = modTime
                } else {
                    modifiedAt = nil
                }
                
                if let createTime = annotationDict["creationDate"] as? TimeInterval {
                    createdAt = createTime
                } else {
                    createdAt = nil
                }
                
                if quote != nil || comment != nil {
                    annotations.append(Annotation(
                        assetId: assetId,
                        quote: quote,
                        comment: comment,
                        chapter: chapter,
                        colorCode: colorCode,
                        modifiedAt: modifiedAt,
                        createdAt: createdAt
                    ))
                }
            }
        }
        
        return annotations
    }
    
    private func parseAnnotationsFromArchived(_ archived: Any, assetId: String) -> [Annotation] {
        // Placeholder for archived data parsing
        // This would need to be implemented based on the actual structure
        return []
    }
    
    private func convertAppleTime(_ appleTime: Int) -> TimeInterval {
        return APPLE_EPOCH_START + TimeInterval(appleTime)
    }
    
    private func getCoverImage(coverURL: String?, bookPath: String?) -> URL? {
        // First try cover URL if available
        if let coverURLString = coverURL, !coverURLString.isEmpty {
            if let url = URL(string: coverURLString) {
                return url
            }
        }
        
        // Fall back to parsing from book path
        if let bookPathString = bookPath, !bookPathString.isEmpty {
            return parseCoverImage(bookPathString: bookPathString)
        }
        
        return nil
    }
    
    private func parseCoverImage(bookPathString: String) -> URL? {
        let fileURL = URL(fileURLWithPath: bookPathString)
        
        // Check if it's an EPUB file
        if bookPathString.hasSuffix(".epub") {
            // Check if file exists as .epub
            if FileManager.default.fileExists(atPath: bookPathString) {
                return extractCoverFromEpub(epubPath: bookPathString)
            }
            
            // If .epub doesn't exist, check if it exists as a decompressed directory
            if FileManager.default.fileExists(atPath: bookPathString, isDirectory: nil) {
                return extractCoverFromDirectory(directoryPath: bookPathString)
            }
        }
        
        // For other formats or if the path doesn't exist, return nil
        return nil
    }
    
    private func extractCoverFromEpub(epubPath: String) -> URL? {
        let fileURL = URL(fileURLWithPath: epubPath)
        guard FileManager.default.fileExists(atPath: epubPath) else { return nil }
        
        do {
            // Create a temporary directory for extraction
            let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
            
            // Unzip the EPUB file (EPUB is a ZIP archive)
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
            process.arguments = ["-q", epubPath, "-d", tempDir.path]
            try process.run()
            process.waitUntilExit()
            
            let coverURL = searchForCoverInDirectory(tempDir, bookId: fileURL.lastPathComponent.replacingOccurrences(of: ".epub", with: ""))
            
            // Clean up temp directory
            try? FileManager.default.removeItem(at: tempDir)
            
            return coverURL
            
        } catch {
            print("Error extracting cover from EPUB: \(error)")
        }
        
        return nil
    }
    
    private func extractCoverFromDirectory(directoryPath: String) -> URL? {
        let directoryURL = URL(fileURLWithPath: directoryPath)
        let bookId = directoryURL.lastPathComponent.replacingOccurrences(of: ".epub", with: "")
        
        return searchForCoverInDirectory(directoryURL, bookId: bookId)
    }
    
    private func searchForCoverInDirectory(_ directory: URL, bookId: String) -> URL? {
        // Look for common cover image locations
        let coverPaths = [
            "OEBPS/cover.jpg", "OEBPS/cover.jpeg", "OEBPS/cover.png",
            "cover.jpg", "cover.jpeg", "cover.png",
            "OEBPS/images/cover.jpg", "OEBPS/images/cover.jpeg", "OEBPS/images/cover.png",
            "Images/cover.jpg", "Images/cover.jpeg", "Images/cover.png",
            "~Cover02.jpg", "~Cover.jpg", "cover.jpeg"  // Common Apple Books patterns
        ]
        
        for coverPath in coverPaths {
            let fullCoverPath = directory.appendingPathComponent(coverPath)
            if FileManager.default.fileExists(atPath: fullCoverPath.path) {
                // Copy cover to a permanent location
                let permanentCoverDir = FileManager.default.temporaryDirectory.appendingPathComponent("book_covers")
                try? FileManager.default.createDirectory(at: permanentCoverDir, withIntermediateDirectories: true)
                
                let coverExtension = fullCoverPath.pathExtension
                let permanentCoverPath = permanentCoverDir.appendingPathComponent("\(bookId).\(coverExtension)")
                
                try? FileManager.default.copyItem(at: fullCoverPath, to: permanentCoverPath)
                
                return permanentCoverPath
            }
        }
        
        // If no standard cover found, look in the first image directory
        let imageDirs = ["OEBPS/images", "Images", ".", "OEBPS"]
        
        for imageDir in imageDirs {
            let imageDirURL = directory.appendingPathComponent(imageDir)
            if FileManager.default.fileExists(atPath: imageDirURL.path) {
                do {
                    let imageFiles = try FileManager.default.contentsOfDirectory(at: imageDirURL, includingPropertiesForKeys: nil)
                        .filter { 
                            let ext = $0.pathExtension.lowercased()
                            return ext == "jpg" || ext == "jpeg" || ext == "png"
                        }
                        .sorted { $0.lastPathComponent < $1.lastPathComponent }
                    
                    if let firstImage = imageFiles.first {
                        let permanentCoverDir = FileManager.default.temporaryDirectory.appendingPathComponent("book_covers")
                        try? FileManager.default.createDirectory(at: permanentCoverDir, withIntermediateDirectories: true)
                        
                        let coverExtension = firstImage.pathExtension
                        let permanentCoverPath = permanentCoverDir.appendingPathComponent("\(bookId).\(coverExtension)")
                        
                        try? FileManager.default.copyItem(at: firstImage, to: permanentCoverPath)
                        
                        return permanentCoverPath
                    }
                } catch {
                    continue
                }
            }
        }
        
        return nil
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

struct Book: Hashable, Codable {
    let id: String
    let title: String
    let author: String
    let cover: URL?
    let annotations: [Annotation]
    
    var latestAnnotationDate: TimeInterval {
        annotations.map { $0.modifiedAt ?? $0.createdAt ?? 0 }.max() ?? 0
    }
}

struct Annotation: Hashable, Codable {
    let id: UUID
    let assetId: String
    let quote: String?
    let comment: String?
    let chapter: String?
    let colorCode: Int64?
    let modifiedAt: TimeInterval?
    let createdAt: TimeInterval?
    
    init(assetId: String, quote: String? = nil, comment: String? = nil, chapter: String? = nil, colorCode: Int64? = nil, modifiedAt: TimeInterval? = nil, createdAt: TimeInterval? = nil) {
        self.id = UUID()
        self.assetId = assetId
        self.quote = quote
        self.comment = comment
        self.chapter = chapter
        self.colorCode = colorCode
        self.modifiedAt = modifiedAt
        self.createdAt = createdAt
    }
}
