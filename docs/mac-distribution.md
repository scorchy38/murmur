# Mac installation and updates

Download **Murmur-Mac.dmg** from a GitHub release. Open the disk image, drag
Murmur onto Applications, then eject the disk. Quit an older running copy before
opening the installed app. The installer is a standard read-only APFS disk image
with a configured Finder window and Applications link, not an executable installer.

## Update behavior

Release builds include Sparkle 2.10.1. Automatic checking and downloading/installing
are on by default, with checks at launch and hourly while running. Sparkle persists
user choices; Settings → Updates can disable checks or automatic installation.
The menu and Settings also offer Check for Updates. Sparkle handles download,
verification, replacement and any required authorization/relaunch UI. Automatic
installation normally occurs on quit; it does not mean forcibly restarting the
app immediately when a GitHub release appears.

Murmur defers a requested update relaunch while recording, processing or recognizing
the recording gesture. It resumes a deferred install after the recording's completion
callbacks have finished. Development fixtures and unit tests do not start automatic
updates. The old CI app has no updater, so it needs a one-time manual installation
of this new build before subsequent updates can arrive through Sparkle.

The stable feed is:
https://github.com/scorchy38/murmur/releases/latest/download/appcast.xml

GitHub's stable/latest release determines the feed; prereleases are not automatically
offered to stable users. During a new release's build, its latest/download feed may
be temporarily unavailable until asset upload finishes. Background checks recover
on the next scheduled check, or use Check for Updates after publication completes.

## Publishing

Commit the updated source/workflow and publish a release with a version tag such as
`v2.0.1`. No ordinary source push by itself publishes an update. The Release workflow:

1. Validates the version tag, tests the Mac code, and sets the marketing version
   from the tag plus an increasing build number from the workflow run and attempt.
2. Archives the universal Mac app, including Sparkle and its trusted public key.
3. Creates the drag-to-Applications DMG using `create-dmg`.
4. Downloads the pinned Sparkle signing tool and validates its SHA-256 digest.
5. Signs the final DMG with the `SPARKLE_PRIVATE_KEY` GitHub Actions secret.
6. Verifies that signature against the public key embedded in the actual archived app.
7. Uploads `Murmur-Mac.dmg`, `appcast.xml` and the existing mobile artifact to the release.

The feed points to an immutable tag-specific DMG download, not the moving latest
DMG URL. Its enclosure length and bundle version match the archived app. Updates
must pass Ed25519 verification before extraction. An unsigned or modified DMG is
rejected, even when downloaded over HTTPS.

The private signing key has been generated under the Keychain account
`com.murmur.updates` on the development Mac and provisioned as the repository's
`SPARKLE_PRIVATE_KEY` secret. Only its public key is committed. Temporary exports
were deleted. Back up that private key securely: replacing it without a supported
key rotation would break trust for already-installed clients. Do not regenerate
it on each release. Sparkle's `generate_keys --account com.murmur.updates -x PATH`
can export it when a secure backup or deliberate migration is needed.

The app still uses the repository's ad-hoc Apple code signing. Ed25519 signing
secures the update payload but does not replace Developer ID signing/notarization
or macOS privacy grants. A Developer ID distribution certificate and notarization
credentials would be needed to add notarized distribution separately.

## Local packaging and validation

```sh
brew install create-dmg
scripts/package-mac.sh path/to/Murmur.app build/Murmur-Mac.dmg
python3 scripts/make-appcast.py \
  --app path/to/Murmur.app --dmg build/Murmur-Mac.dmg \
  --tag v2.0.0 --sign-tool path/to/Sparkle/bin/sign_update \
  --output build/appcast.xml
```

`make-appcast.py` uses the dedicated Keychain identity locally, or pipes the CI
secret to the signer over stdin. Secrets are never passed on the command line or
included in the feed. A CryptoKit helper validates the signature against the
bundled public key before writing the feed.

Validated locally: universal Release archive; 16 native tests including deferred
relaunch and one-time resume; disk-image checksum; mounted app signature and
Applications symlink; Finder layout in a real window; signed feed/DMG consistency;
and rejection of a payload modified after signing. The prior 13 shared voice tests
remain unchanged. No GitHub release was published and no installed app was replaced.
Live download/replacement from the public feed requires the first release built
with this workflow.

## Ad-hoc launch compatibility

Ad-hoc archives must set `ENABLE_HARDENED_RUNTIME=NO`. An ad-hoc executable has
no Apple signing Team ID, so hardened runtime's same-team library validation can
reject the embedded Sparkle framework at launch even when `codesign --verify`
reports an intact bundle. Certificate-signed builds keep the project's hardened
runtime default enabled; this override applies to the current ad-hoc CI archive.

The packaging script rejects the incompatible ad-hoc/runtime combination. CI also
runs `scripts/smoke-test-mac.py` against the actual archived executable before
packaging. The smoke check must reach initialized menu-bar UI, not merely pass a
signature check. It disables update checks for that process and never starts
microphone capture or local-network sync.

The 2.0.1 repair was verified by launching both the archived executable and the
installed `/Applications/Murmur.app`. System Events confirmed the running app's
Murmur menu-bar item. A packaging regression check rejects the previous broken
archive. A copy of the replaced local app is retained under `build/backups`.

## Before the first update feed is published

A GitHub release containing only the legacy ZIP/IPA does not provide a Sparkle
appcast. Before starting Sparkle, Murmur probes the configured feed with an
8-second request timeout and a 10-second resource bound. A 404 displays an inline
“Updates aren’t published yet” explanation; it does not open an error dialog or
claim the app is up to date. Network failures clear checking state and allow retry.
The app retries feed discovery hourly while automatic checks are enabled; once a
feed is available, Sparkle owns the normal update schedule.

The menu's update action opens Settings → Updates so results have a visible home.
The gear button only opens Settings. Neither action publishes a release. The feed
becomes available when the updated Release workflow publishes its signed artifacts.
