# Song Manager — TODOs

## Done
- [x] Auth-expired toast: `DropboxSourceError.authExpired` (string-match `authError`/`expired_access_token` from SwiftyDropbox `CallError`), `SongStore.handleDropboxError` drops `source` so `ContentView`'s Connect sheet re-presents, plus a top toast (iOS port of macOS `ToastView`) that auto-dismisses in 5s.
- [x] Waveform auto-scroll vs manual scroll: `onScrollPhaseChange` on the timeline `ScrollView` sets `userScrolling`; `proxy.scrollTo` is suppressed while interacting and for 2.5s after the user lifts (`resumeAutoScroll` Task).
- [x] Smooth playhead: AVPlayer time observer dropped from 0.5s → 0.05s (20Hz). `MPNowPlayingInfoCenter` push throttled to ~2Hz inside the callback so we don't spam the lock-screen.
- [x] "Burning Bridges" play button forced black (light artwork makes white play icon disappear).
- [x] Card play button restored as a clear-glass circle (56pt, bottom-trailing, 22pt white play icon). Uses `.glassEffect(.clear, in: Circle())`. Pill overlay still hidden.
- [x] Home grid background: solid `Color.black` (dropped blurred album-art entirely).
- [x] Big title overlay on artwork (system heavy 28pt, top-left, white + soft shadow). Pill overlay hidden (code preserved in `SongCard.swift` `pillOverlay`).
- [x] Slow launch / "activity-date cache not used on relaunch" — root cause was `CIAreaAverage` summarize running on the main actor for every album art on launch. Two ~7MB JPEGs took ~5s each. Fix: skip `applyArtSummary` calls in `loadAlbumArt` since the only consumer (`pillOverlay`) is hidden. Cache itself was fine.
- [x] Home grid background: random album art (from allow-list: moonlit, burning bridges, the only, veil, falling into the sun), blurred 60pt + scale 1.4×, no overlay.
- [x] Dropbox PKCE OAuth via SwiftyDropbox. App key in `DropboxConfig.swift` (public, committable), refresh token persisted in Keychain. Manual `Info-iOS.plist` at repo root registers the `db-<APPKEY>` URL scheme (synchronized iOS folder would have auto-included it as a Resource). `.onOpenURL` in `Song_Manager_iOSApp` calls `handleRedirectURL` and posts `.dropboxAuthDidChange`; `ContentView` listens and rebuilds the source.

## Open
- [ ] Voice-to-note feature

## Notes for later
- If we revive the pill / want tinted glass anywhere, re-enable `applyArtSummary` but: (a) move `summarize` off the main actor (`Task.detached`), (b) downscale the CIImage to ~64×64 before `CIAreaAverage`, and (c) persist the result to a sidecar `artTints.json` like `activityDates.json`.
- Dropbox app must be **Public** (PKCE) for the runtime refresh — SwiftyDropbox doesn't send a client secret on refresh. Redirect URI registered in the Dropbox console: `db-cuti3ayzmx7e7ma://2/native/`.
