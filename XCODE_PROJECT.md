# Xcode Project Setup

This repository is now configured as a proper Xcode project for macOS development.

## Project Structure

The repository now includes:

- **NoteHarvester.xcodeproj** - Main Xcode project file
- **Package.swift** - Swift Package Manager configuration for dependencies
- **NoteHarvester/** - Main app source code
  - `NoteHarvesterApp.swift` - SwiftUI app entry point
  - `Views/ContentView.swift` - Main user interface
  - `Services/DatabaseManager.swift` - Core business logic
  - `Assets.xcassets` - App icons and visual assets
  - `NoteHarvester.entitlements` - App permissions and capabilities
- **NoteHarvesterTests/** - Unit tests
- **NoteHarvesterUITests/** - UI automation tests

## Dependencies

The project uses Swift Package Manager to manage dependencies:

- **SQLite.swift** (0.15.3+) - Database access for Apple Books data

### Note on EPUBKit Dependency

The original code used EPUBKit for EPUB cover image parsing, but this dependency has been temporarily removed due to repository availability issues. The app will function correctly without it, but book cover images will not be displayed until an alternative EPUB parsing library is integrated.

Alternative EPUB libraries to consider:
- [FolioReaderKit](https://github.com/FolioReader/FolioReaderKit)
- [KFEpubKit](https://github.com/kidsfm/KFEpubKit)
- Custom EPUB parsing implementation

## Opening the Project

1. **Using Xcode**: Open `NoteHarvester.xcodeproj` in Xcode
2. **Using Swift Package Manager**: Run `swift package generate-xcodeproj` (alternative)

## Build Requirements

- **macOS 12.0+** (deployment target)
- **Xcode 15.0+** (recommended)
- **Swift 5.9+**

## Building and Running

1. Open the project in Xcode
2. Select the "NoteHarvester" scheme
3. Choose your target Mac as the destination
4. Build and run with ⌘+R

The app will automatically download and configure the required dependencies through Swift Package Manager.

## Testing

The project includes two test targets:

- **NoteHarvesterTests** - Unit tests for core functionality
- **NoteHarvesterUITests** - UI automation tests

Run tests with ⌘+U in Xcode or using the Test navigator.

## Project Configuration

The Xcode project is configured with:

- **Product Name**: NoteHarvester
- **Bundle Identifier**: com.noteharvester.NoteHarvester
- **Platform**: macOS (12.0 minimum)
- **Language**: Swift 5.0
- **UI Framework**: SwiftUI
- **Code Signing**: Automatic

## Development Notes

- The project uses modern Swift and SwiftUI patterns
- Dependencies are managed via Swift Package Manager (no CocoaPods or Carthage needed)
- The shared scheme is committed for team collaboration
- User-specific Xcode settings (xcuserdata) are excluded from version control