# Shaudi Agent Instructions

## Project
Native iOS app using Swift, SwiftUI, SwiftData, and Apple frameworks.

## Development principles
- Keep architecture simple.
- Prefer built-in Apple frameworks.
- Do not add third-party dependencies unless explicitly requested.
- Do not introduce service/repository layers or abstractions without a concrete need.
- Do not modify unrelated working code.
- Make the smallest coherent implementation that satisfies the task.

## Data
- Track is a Library object.
- Tracks may belong to zero or multiple Playlists.
- Removing a Track from a Playlist must not delete it from Library.
- Deleting a Playlist must not delete its Tracks.

## Verification
- Build the project after meaningful code changes.
- Fix only failures caused by the current task.
- Report files changed, important decisions, assumptions, and build result.

## Scope
- Only implement functionality explicitly requested in the current task.
- Do not opportunistically implement future roadmap features.
