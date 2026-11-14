# Releasing BCI Workspace (macOS, Developer ID)

BCI Workspace ships outside the App Store as a signed, notarized, stapled DMG. One
command builds it on an Apple Silicon Mac that holds the signing material:

```sh
scripts/bootstrap.sh            # once per checkout/worktree
scripts/release.sh 0.1.0        # optional 2nd arg: CFBundleVersion (default: commit count)
```

Output in `build/release/`:

- `BCIWorkspace-<version>.dmg` — the app and an `/Applications` link, signed, notarized, stapled
- `BCIWorkspace-<version>.dmg.sha256`
- `work/` — the stapled `.app`, notary JSON, and the `xcodebuild` log (safe to delete)

## What the script does

1. Creates a throwaway keychain, imports the Developer ID Application identity into it,
   and puts it at the front of the user keychain search list. The login keychain is never
   modified; a `trap` restores the original search list and deletes the keychain on normal
   exit, error or Ctrl-C. If the script is killed hard (SIGKILL, crash), restore the list by
   hand: `security list-keychains -d user -s ~/Library/Keychains/login.keychain-db`.
2. `scripts/bundle_worker.sh --sign <identity>` builds the arm64 Python worker and signs
   every Mach-O in it (interpreter, `.so`, `.dylib`) one file at a time with
   `--options runtime --timestamp`.
3. `xcodegen generate`, then a Release build. Release in `project.yml` signs with the
   personal Developer ID (team `V56DG94ZL5`), hardened runtime on, `--timestamp`, no
   `get-task-allow`. Xcode signs the embedded BrainFlow dylib and the app last, sealing
   the already-signed worker under `Contents/Resources/worker/`. Versions come from
   `MARKETING_VERSION` / `CURRENT_PROJECT_VERSION`, which the script overrides.
4. Verifies `codesign --verify --deep --strict` and then every Mach-O in the bundle
   individually: Developer ID authority for the team, the `runtime` flag, a secure timestamp.
5. Notarizes a zip of the app with `notarytool submit --wait` (App Store Connect API key,
   no Apple ID password), staples the app, builds the DMG with `hdiutil`, signs it,
   notarizes and staples it too. A rejected submission prints the notary log and stops.
6. Runs `spctl` on both and stops unless each reports `source=Notarized Developer ID`.
7. On exit (once the worker step has started), deletes `build/worker-dist` so the next Debug build goes back to the dev venv
   (the copy phase also removes a previously embedded worker when the dist is absent;
   tests expect the dev venv).

## Entitlements

None. The app and the worker interpreter run under the hardened runtime with no
exceptions: every library either process loads is signed by the same team, so library
validation passes, and neither needs JIT or unsigned executable memory. App Sandbox is
off (the app launches a bundled interpreter and reads projects anywhere the user picks).
Add an exception only when a run proves it is needed, scoped to the one binary that needs it.

## Where the secrets live

Nothing secret is in the repository, and the script never prints a secret. It reads, from
outside the repo (each path overridable by an environment variable named in the script header):

- **Developer ID Application certificate + private key**: a `.p12` file and a separate
  file holding its password, in the owner's private signing folder under `~/.config/`.
- **Notarization**: an App Store Connect API key (`.p8`) under
  `~/.appstoreconnect/private_keys/`, with its key ID and issuer ID in an env file in
  `~/.appstoreconnect/`.

If either is missing the script stops before building.

## Checking a build by hand

```sh
spctl -a -vvv -t install build/release/BCIWorkspace-<v>.dmg
xcrun stapler validate build/release/BCIWorkspace-<v>.dmg
spctl -a -vvv /Volumes/BCI\ Workspace\ <v>/BCIWorkspace.app
```

For a first-launch test as a downloader sees it, copy the app out of the mounted DMG, add a
quarantine attribute (`xattr -w com.apple.quarantine "0081;$(printf %x $(date +%s));Safari;" BCIWorkspace.app`),
open it, and run an evaluation of the bundled example so the worker starts.

## Not automated yet

Publishing (tags, GitHub Releases, a CI release workflow with repository secrets) is a
separate step that needs owner approval. A clean-machine launch (no Xcode, Homebrew or uv)
is still a phase-0 gate.
