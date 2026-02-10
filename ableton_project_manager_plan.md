# macOS Ableton Project Manager – Implementation Plan

## 1. Purpose
A macOS app that manages references to existing Ableton Live project folders.
The app does NOT create projects. It only reads files, opens files, and duplicates existing ALS files with version bumps.

---

## 2. Core Features

### 2.1 Multiple Project References
- User can add multiple existing Ableton project folders.
- Each project is stored as a persistent reference using security-scoped bookmarks.
- Projects are displayed in a grid UI.

---

### 2.2 Open Latest Bounce
Definition of “latest”:
- Newest file by modification date inside the `bounces/` folder.

Behavior:
1. Resolve `<project>/bounces/`
2. Filter audio files (wav, aif, aiff, mp3)
3. Sort by modification date
4. Open newest file via `NSWorkspace`

Edge cases:
- Folder missing → disable button
- Folder empty → disable button

---

### 2.3 Display Album Art
- Folder: `_ALBUM ART/`
- Supported formats: png, jpg, jpeg, tiff, webp
- Select first or newest image
- Display as full-bleed card image

Fallback:
- Placeholder gradient if missing

---

### 2.4 Duplicate Latest Ableton File (Version Bump)
Definition of “latest”:
- Determined by filename version, not modification date.

Steps:
1. Scan project root for `.als` files
2. Parse semantic-style version numbers from filenames
   - Example: `Song 1.2.1.als`
3. Compare versions lexicographically
4. Select highest version
5. Increment last numeric segment
   - `1.2.1` → `1.2.2`
6. Duplicate file with bumped version name
7. Optionally auto-open new ALS

Fallback:
- If no version exists, append `1.0`

---

## 3. UI Design

### 3.1 Layout
- Grid-based layout (`LazyVGrid`)
- Responsive columns based on window width
- “Add Project” card included in grid

---

### 3.2 Project Card
- Album art (primary visual)
- Footer with:
  - Project name
  - Latest ALS version
- Hover-only actions:
  - Open Latest Bounce
  - Duplicate ALS

Disabled actions if required files are missing.

---

## 4. Data Model

### ProjectReference
- id (UUID)
- displayName
- rootBookmark (security-scoped)
- cached metadata:
  - latestBounceURL
  - albumArtURL
  - latestALSURL
  - latestVersionString

---

## 5. Architecture

### Services
- ProjectStore
  - Add/remove/load/save project references
- ProjectScanner
  - Scan folders for bounces, art, ALS
- FileActions
  - Open bounce
  - Duplicate ALS
- VersionService
  - Parse, compare, bump versions

---

## 6. Platform Requirements
- SwiftUI
- macOS sandboxed app
- Security-scoped bookmarks
- NSWorkspace for opening files

---

## 7. Explicitly Out of Scope
- Creating Ableton projects
- Editing ALS contents
- Sample, stem, or master management
- Renaming files beyond version bumping

---

## 8. MVP Milestones
1. Grid UI with mock data
2. Add project folder + persistence
3. File scanning + album art display
4. Open latest bounce
5. Duplicate ALS with version bump

