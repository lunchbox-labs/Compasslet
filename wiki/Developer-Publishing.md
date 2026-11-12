# Publishing

For maintainers shipping App Store and TestFlight builds. Two workflows do the
work, and both run only manually from `main`:

- [Publish](https://github.com/lunchbox-labs/compasslet/blob/main/.github/workflows/publish.yml)
  uploads a build, updates the listing and submits the version for App Review.
- [Release](https://github.com/lunchbox-labs/compasslet/blob/main/.github/workflows/release.yml)
  releases the approved version on the App Store, tags its commit and publishes its
  GitHub Release.

Neither starts from a push, a merge, a tag or a GitHub Release. Both use the
`release` environment, which should allow only `main`. The workflows do not
configure credentials or permissions.

## Submitting a version

Before running Publish:

1. In App Store Connect, create the iOS version (it must match `MARKETING_VERSION`),
   its locales and the App Review contact details. The workflows never create these.
2. Merge the version bump and any release copy changes into `main`, including
   `app-store/review-notes.txt` for the App Review notes. Without that file the notes in
   App Store Connect are left as they are.

Run Publish with `submit` on (the default). It:

1. archives, signs and uploads a build numbered `<run number>.<attempt>`;
2. captures the listing screenshots at the same commit;
3. syncs the release copy and TestFlight notes;
4. syncs the App Review notes and replaces the version's listing screenshots;
5. waits up to about 20 minutes for Apple to process the build, attaches it to the
   version, sets the version to release manually and submits it for App Review.

With `submit` off, Publish uploads a build for TestFlight only. It skips the listing
screenshots and the submission, and still syncs the copy and App Review notes while
the version is editable.

Uploads are eligible for both internal TestFlight testing and App Store submission.
A build previously uploaded as TestFlight Internal Only cannot be used for an App
Store release; upload a new build without that restriction.

A failure after the upload does not undo it. Check App Store Connect and the job log,
then re-run only the failed jobs to retry with the same build; re-running the whole
workflow uploads another build. Once a version is submitted with a build, running
the same attempt again reports `ALREADY SUBMITTED` and changes nothing. If Apple
sends the version back, fix it and run Publish again: the new build replaces the old
one in the returned submission, which is submitted again. A run that stopped after
adding the version to a submission finishes sending it. Publish stops without
submitting while another iOS submission is waiting for or in review.

## Releasing a version

Once Apple approves the version, App Store Connect shows it as Pending Developer
Release. Run Release from `main` before bumping `MARKETING_VERSION` for the next
version, since it releases the version that `main` names. It:

1. finds that version's approved build and the Publish run and commit it came from,
   and stops if the version isn't approved, its GitHub Release is already published or
   its tag is on another commit;
2. captures every screen at that commit in light and dark on the largest and
   smallest iPhones, top of each screen only (input `screenshots`, on by default);
3. releases the version on the App Store (input `app-store-release`, on by default);
4. creates a draft GitHub Release named `Compasslet <version>` with notes generated
   from the merged pull requests, attaches the screenshots, tags the build's commit
   `v<version>` and publishes the release.

Turn `app-store-release` off for a version that is already live, such as 1.0, to tag
it and publish its GitHub Release only. With it off, Release stops unless the version is
already on the App Store. Only the job that tags and publishes can write
to the repository, using the workflow's own token.

Release never moves or replaces a tag or a published release. If a run stops after the
App Store release, re-run its failed jobs, or run Release again with
`app-store-release` off. A tag already on the build's commit is reused and an
unpublished draft from the earlier run is replaced. Release stops at a draft for the tag
that it didn't make, so publish or delete that draft first.

Published releases are [immutable](https://docs.github.com/en/code-security/concepts/supply-chain-security/immutable-releases):
assets cannot be added, replaced or deleted after publication, so Release attaches
every image before publishing.

## App Store listing screenshots

Publish captures the compass in light and dark on iPhone 17 (the `listing` set of the
[Screenshots workflow](https://github.com/lunchbox-labs/compasslet/actions/workflows/screenshots.yml))
and makes those two images the version's iPhone 6.3" screenshots in each locale in
`app-store/`, removing the old ones once the new ones are in. Screenshots for other sizes are left as they are. Running Screenshots
manually with `set` set to `listing` shows the images before a submission.

Apple's [screenshot specifications](https://developer.apple.com/help/app-store-connect/reference/app-information/screenshot-specifications/)
list one required iPhone size, iPhone with Dynamic Island (medium display), which
iPhone 17 is. The app is iPhone only, so no iPad screenshots are needed
([#309](https://github.com/lunchbox-labs/compasslet/issues/309)). Apple Watch
([#304](https://github.com/lunchbox-labs/compasslet/issues/304)) and iPhone Duo
([#305](https://github.com/lunchbox-labs/compasslet/issues/305)) screenshots are
left out of the first release. Apple says iPhone Duo screenshots become required
from April 2027 for apps built with the iOS 27.1 SDK or later.

## Credentials and signing

Keep these in the `release` environment, key IDs as Variables and everything else
as Secrets:

| Variable | Secret | Apple role |
| --- | --- | --- |
| `ASC_DEVELOPER_API_KEY_ID` | `ASC_DEVELOPER_API_PRIVATE_KEY_BASE64` | Developer, for uploads |
| `ASC_METADATA_API_KEY_ID` | `ASC_METADATA_API_PRIVATE_KEY_BASE64` | App Manager, for the listing, App Review and releases |

Private-key secrets contain base64-encoded `.p8` contents. Both team keys share
repository Variable `ASC_API_ISSUER_ID`; keep `APPLE_TEAM_ID` as a repository
Variable too. Match each key ID to its private key. Metadata has no fallback to
the upload key, and the upload script does not read the former `ASC_API_KEY_ID`
or `ASC_API_PRIVATE_KEY_BASE64` names. Verify the metadata key's actual role and
app access: successful build upload does not prove permission to edit listings,
submit for review or release.

The environment also needs these signing Secrets:

| Secret | Contents |
| --- | --- |
| `IOS_DISTRIBUTION_P12_BASE64` | Base64 distribution certificate and private-key `.p12` |
| `IOS_DISTRIBUTION_P12_PASSWORD` | Password for that `.p12` |
| `IOS_APP_PROFILE_BASE64` | Base64 iPhone distribution profile |
| `IOS_ACTIVITY_PROFILE_BASE64` | Base64 Live Activity distribution profile |

Profiles must match the app's identifiers, entitlements and signing certificate,
including Apple's approved CarPlay capability. Never commit credential values.
GitHub uses a same-named repository secret if an environment secret is absent;
environment-only isolation therefore requires removing repository duplicates after
validating their replacements. Do not create a repository fallback for the metadata
private key. The environment needs to allow only `main`.

Keep original private keys securely: GitHub cannot reveal stored secret values and
Apple permits downloading a `.p8` only once. Moving storage does not require key
rotation. When replacing a key, validate its matching ID and secret before revoking
the old key.

## Release copy

Edit `app-store/<locale>/` and `app-store/review-notes.txt` before uploading the
build that should use them. Publish uses the uploaded commit, not newer edits on `main`.

| File | Destination | Limit |
| --- | --- | --- |
| `description.txt` | App Store description and app-wide TestFlight description | 4,000 characters |
| `promotional-text.txt` | App Store promotional text | 170 characters |
| `keywords.txt` | App Store keywords | 100 UTF-8 bytes |
| `whats-new.txt` | App Store release notes | 4,000 characters |
| `what-to-test.txt` | Uploaded TestFlight build's testing instructions | 4,000 characters |
| `name.txt` | App Store name | 30 characters |
| `subtitle.txt` | App Store subtitle | 30 characters |
| `privacy-policy-url.txt` | Privacy policy URL | One `https` URL, 2,000 characters |
| `privacy-choices-url.txt` | Privacy choices URL | One `https` URL, 2,000 characters |
| `support-url.txt` | Support URL | One `https` URL, 2,000 characters |
| `marketing-url.txt` | Marketing URL | One `https` URL, 2,000 characters |

`app-store/review-notes.txt` holds the App Review notes, which aren't localized
(4,000 characters). The review contact's name, email and phone stay in App Store
Connect and never go in the repository; Publish stops if the notes hold an email address
or phone number.

Missing files leave fields unchanged; blank or overlong files fail validation.
The TestFlight description also affects existing beta builds. Release notes and
testing instructions are separate fields, never substituted for each other.

After upload, sync updates only supplied, changed fields in existing localizations.
App Store edits require an existing editable iOS version matching the archive's
marketing version. Name, subtitle and privacy URLs belong to the app info record
rather than a version, and are updated only when exactly one app info is editable.
Review `UPDATED`, `UNCHANGED` and `SKIP` messages: missing or noneditable versions
and missing locales are skipped. Create any needed version or locale in App Store
Connect. Sync does not create resources.

When testing instructions are supplied, sync waits up to about ten minutes for
the exact uploaded build to finish processing. A metadata failure does not undo
the accepted upload or earlier metadata edits.
