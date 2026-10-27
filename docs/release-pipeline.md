# Native release ownership

The canonical migration preserves app/extension identities, iOS/macOS 27 floors,
package revisions, entitlements, public contributor isolation, fleet delivery and
planned gateway recovery. It removes project generation and Fastlane without
moving product sources or changing runtime behavior.

The committed JSON Xcode project owns target membership and schemes. Synchronized
folders discover new Swift files. Mac exclusions remain explicit for iOS-only
files. Shared subsets compiled by extensions retain explicit membership. Plists
live in Config/InfoPlists; private local configuration stays ignored by filename.

Public CI compiles every shipping platform and test target and runs the existing
70 product checks on an available iPhone running iOS 27.0. This preserves the
existing worker's iPhone 17 Pro / iOS 27.0 baseline. The public tag workflow admits
the exact green main commit before exposing signing credentials, reserves
per-platform ASC build numbers and persists
one reservation artifact per run. Archives, verified exports and signed entitlement
checks run on hosted macOS. This keeps public repositories free of personal
runners and avoids billed hosted builds in the private deployment repository.

The private workflow independently checks tag identity, main ancestry, ordering,
the public release run and green main CI. Only it may use the Mini. Gateway
build/deploy uses the existing installer and exact-turn recovery. A separate job
archives the same admitted commit locally for ad hoc iOS and Developer ID Mac
delivery, using the local signing keychain, existing cache/capacity leases and
four-job host cap. The tag is the version in both paths. Direct delivery keeps
the existing monotonic semver-derived build numbers; hosted App Store builds use
the ASC reservation. Neither path depends on the other's build numbers.

The release cache publishes the direct artifacts and dSYMs for fleet catch-up.
The Mac direct completion marker replaces the old App Store package as the
publication boundary. Existing releases through 3.73.0 keep their old package
marker so retained signed cache entries remain readable. Both paths verify
source/version/build stamps, signatures and required entitlements before delivery.

The app has no minimum gateway release-version gate. The existing protocol and
capability compatibility remains authoritative, so app upload and gateway deploy
run independently. The private GitHub release joins both delivery paths and the
public processing result. An install, upload, processed build, store preparation,
fleet catch-up and user acceptance remain separate outcomes.

A same-run retry restores the build reservation. The template's upload fence
checks whether any earlier run attempt started the platform's upload step. A
later attempt checks ASC for the exact reserved identity for up to 15 minutes;
when an upload started but Apple exposes no matching build, it stops for
reconciliation instead of uploading again. Artifacts expire after bounded retention; an expired reservation
is not permission to upload that release again. A code change requires the next
patch tag. Published tags never move.

RemoteCoder has never been submitted to the App Store. Its editable iOS and Mac
1.0 drafts become the tag version with manual release. Noneditable versions are preserved. Existing screenshots and internal TestFlight distribution
policy are preserved because this repository has no screenshot capture source.
The pipeline prepares editable versions only; it never submits App Review or
presses Release.

Rejected alternatives: putting cloud signing on the Mini uses its installed
Distribution certificate and defeats cloud signing; putting hosted archives in
the private repository multiplies billed minutes. Transferring hosted archives
would avoid the local archives, but GitHub artifact downloads require an Actions
read credential for the public repository. The existing public-release token has
Contents write only, and extending a fine-grained PAT requires Emil in GitHub's
UI. Keep the established independent direct builds; revisit archive transfer only
if measured Mini build time justifies that credential boundary. No new token,
permission or runtime protocol change is required.

## Deferred product observation

On iPhone Duo / iOS 27.1,
`RemoteCoderTests/TranscriptScrollRenderingTests/aShortReplyUnderATallComposerShowsNoJumpControl()`
renders a jump-to-latest control beneath a short reply when the fixture's composer
is 400 points tall. The view is 466 × 678 points and its adjusted transcript
viewport is 175.67 points tall. The control is visible in the
[captured screenshot](images/duo-27.1-short-reply-jump-control.png) from
[the hosted test failure](https://github.com/emileberhard/RemoteCoder/actions/runs/40565329077).
Product Swift is unchanged from 3.73.0; the old Tuist project has not been tested
on this device/runtime combination. Keep this as separate product work after
the migration. The migration retains all 70 checks on the existing iOS 27.0
baseline rather than changing jump-control behavior.
