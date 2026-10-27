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
product gates. The public tag workflow admits the exact green main commit before
exposing signing credentials, reserves per-platform ASC build numbers and persists
one reservation artifact per run. Archives, verified exports and signed entitlement
checks run on hosted macOS. This keeps public repositories free of personal
runners and avoids billed hosted builds in the private deployment repository.

The private workflow independently checks tag identity, main ancestry, ordering,
the public release run and green main CI. Only it may use the Mini. Gateway
build/deploy uses the existing installer and exact-turn recovery. A separate job
fetches the public run's archives, checks their source/version/build receipts,
exports ad hoc and Developer ID artifacts and publishes them through the existing
release cache and fleet catch-up. It does no app compilation. ASC-reserved build
numbers travel with cache receipts. Releases through 3.73.0 retain their historical
semver-derived numbers so existing signed cache entries remain readable.

The app has no minimum gateway release-version gate. The existing protocol and
capability compatibility remains authoritative, so app upload and gateway deploy
run independently. The private GitHub release joins both delivery paths and the
public processing result. An install, upload, processed build, store preparation,
fleet catch-up and user acceptance remain separate outcomes.

A same-run retry restores the build reservation. Before upload, an immutable
artifact records the attempt's exact identity. A later attempt first checks ASC;
when the fence exists but Apple exposes no matching build, it stops for
reconciliation instead of uploading again. Artifacts expire after bounded
retention; an expired reservation/fence is not permission to upload that release
again. A code change requires the next patch tag. Published tags never move.

RemoteCoder has never been submitted to the App Store. Its editable iOS and Mac
1.0 drafts become the tag version with manual release. Noneditable versions are preserved. Existing screenshots and internal TestFlight distribution
policy are preserved because this repository has no screenshot capture source.
The pipeline prepares editable versions only; it never submits App Review or
presses Release.

Rejected alternatives: putting cloud signing on the Mini uses its installed
Distribution certificate and defeats cloud signing; putting hosted archives in
the private repository multiplies billed minutes; rebuilding on the Mini wastes
the hosted artifacts and splits provenance. New cross-repository publishing
infrastructure and changes to the runtime protocol are unnecessary.
