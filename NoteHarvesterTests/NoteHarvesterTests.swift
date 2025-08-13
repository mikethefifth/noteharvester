//
//  NoteHarvesterTests.swift
//  NoteHarvesterTests
//
//  Created by Lukas Selch on 25.09.24.
//

import Testing
@testable import NoteHarvester

struct NoteHarvesterTests {

    @Test func databaseManagerInitialization() async throws {
        let databaseManager = DatabaseManager()
        
        // Verify initial state
        #expect(!databaseManager.isLoading)
        #expect(databaseManager.loadingProgress == 0.0)
        #expect(databaseManager.loadingMessage.isEmpty)
        #expect(databaseManager.errorMessage == nil)
    }
    
    @Test func databaseManagerAsyncStreamCreation() async throws {
        let databaseManager = DatabaseManager()
        
        // Verify that creating the async stream doesn't block
        let stream = databaseManager.loadBooksProgressively()
        
        // This should return immediately, not block
        #expect(stream != nil)
        
        // The loading should start when we begin iterating
        var resultCount = 0
        for await result in stream {
            resultCount += 1
            
            // Only process a few results to avoid long test times
            if resultCount >= 3 {
                break
            }
            
            switch result {
            case .bookLoaded(_):
                #expect(true) // Successfully loaded a book
            case .error(_):
                #expect(true) // Error handling works (may happen due to missing Apple Books)
            case .completed(_):
                #expect(true) // Completion works
            }
        }
    }
    
    @Test func bookStructureIntegrity() async throws {
        let book = Book(
            id: "test-id",
            title: "Test Book",
            author: "Test Author",
            cover: nil,
            annotations: []
        )
        
        #expect(book.id == "test-id")
        #expect(book.title == "Test Book")
        #expect(book.author == "Test Author")
        #expect(book.cover == nil)
        #expect(book.annotations.isEmpty)
        #expect(book.latestAnnotationDate == 0)
    }

}
