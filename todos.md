# Song Manager — TODOs

## Done
- [x] Big title overlay on artwork (system heavy 28pt, top-left, white + soft shadow). Pill overlay hidden (code preserved in `SongCard.swift` `pillOverlay`).
- [x] Slow launch / "activity-date cache not used on relaunch" — root cause was `CIAreaAverage` summarize running on the main actor for every album art on launch. Two ~7MB JPEGs took ~5s each. Fix: skip `applyArtSummary` calls in `loadAlbumArt` since the only consumer (`pillOverlay`) is hidden. Cache itself was fine.
- [x] Home grid background: random album art (from allow-list: moonlit, burning bridges, the only, veil, falling into the sun), blurred 60pt + scale 1.4×, no overlay.
- [x] Dropbox PKCE OAuth via SwiftyDropbox. App key in `DropboxConfig.swift` (public, committable), refresh token persisted in Keychain. Manual `Info-iOS.plist` at repo root registers the `db-<APPKEY>` URL scheme (synchronized iOS folder would have auto-included it as a Resource). `.onOpenURL` in `Song_Manager_iOSApp` calls `handleRedirectURL` and posts `.dropboxAuthDidChange`; `ContentView` listens and rebuilds the source.

## Open
- [ ] Pill play button too small *(likely obsolete now that pill is hidden — revisit if pill comes back)*
- [ ] Player waveform: auto-scroll fights manual scroll
- [ ] Player scrubber playhead movement should be smooth, not stepwise
- [ ] Voice-to-note feature
- [ ] Surface auth-expired errors as a toast / re-trigger Connect, instead of the silent-dismiss the play flow currently does.

## Notes for later
- If we revive the pill / want tinted glass anywhere, re-enable `applyArtSummary` but: (a) move `summarize` off the main actor (`Task.detached`), (b) downscale the CIImage to ~64×64 before `CIAreaAverage`, and (c) persist the result to a sidecar `artTints.json` like `activityDates.json`.
- Dropbox app must be **Public** (PKCE) for the runtime refresh — SwiftyDropbox doesn't send a client secret on refresh. Redirect URI registered in the Dropbox console: `db-cuti3ayzmx7e7ma://2/native/`.
