# One-to-one messenger

An Android-first messenger in which each account can have **one active partner**. A pairing remains until either person disconnects. The next pairing starts with an empty conversation.

**Project status:** Flutter Android scaffold and product plan. Cloud resources, messaging, media, and calling have not been implemented or deployed.

## Build the current Android preview

This repository currently builds a welcome screen, not a working messenger. On this Mac, the shell defaults to Java 11, which is too old for the generated Gradle build. Use the installed Java 24 for the build:

```sh
cd /Users/yashpatodkar/Documents/aida
JAVA_HOME=/Users/yashpatodkar/Library/Java/JavaVirtualMachines/openjdk-24.0.2/Contents/Home flutter pub get
JAVA_HOME=/Users/yashpatodkar/Library/Java/JavaVirtualMachines/openjdk-24.0.2/Contents/Home flutter build apk --debug
JAVA_HOME=/Users/yashpatodkar/Library/Java/JavaVirtualMachines/openjdk-24.0.2/Contents/Home flutter build apk --release
```

The APKs are at `build/app/outputs/flutter-apk/app-debug.apk` and `build/app/outputs/flutter-apk/app-release.apk`. The release-mode preview is smaller. To install it on a connected Android phone with USB debugging enabled:

```sh
~/Library/Android/sdk/platform-tools/adb install -r build/app/outputs/flutter-apk/app-release.apk
```

You can also copy the APK to an Android phone and open it there. The current release build uses Flutter's debug signing key and the placeholder application ID `com.example.aida`. Configure a unique application ID and your own release signing key before wider distribution; a later build with a different key may require uninstalling this preview first.

## Work needed for a two-phone test

1. Configure Cognito email sign-in and connect the Flutter app to it.
2. Deploy the pairing API and database. Enforce one active pair per account with conditional, transactional writes.
3. Add real-time text messages and private image/video upload and download.
4. Deploy LiveKit on AWS and add pair-scoped voice/video calls in Flutter.
5. Add Android push notifications and the disconnect/deletion workflow.
6. Test with two Android phones on separate networks, then build a signed test release for your friend.

## Product behavior

1. A person signs in and sees either **Invite someone** or their current partner's conversation.
2. An unpaired person can create a single-use invitation. The app displays a short code and a link that can be sent through any existing messenger. The invitation expires after 24 hours and can be revoked.
3. The recipient installs the app, signs in, opens the link or enters the code, sees the inviter's display name, and taps **Connect**. The link itself never pairs accounts without explicit acceptance.
4. The server accepts only if **both accounts are still unpaired**. It consumes all outstanding invites for both accounts. If either person paired elsewhere, acceptance fails and the recipient sees an explanation.
5. The active pair can exchange text, images, and videos and start voice or video calls. There is no group conversation, contact search, or second active chat.
6. Either person can tap **Disconnect** and confirm a clear warning that the shared conversation will be deleted for both. Both immediately return to **Invite someone**. The old invitation and conversation cannot be reopened, even if the same people pair again.

## Pairing state

`UNPAIRED -> INVITED -> PAIRED -> DISCONNECTING -> UNPAIRED`

An invite is an option while unpaired, not a reserved partner. Invites have random, unguessable tokens, one use, an expiry, and rate limits. Pair acceptance is a single database transaction that reserves both users and creates a new `pairId`. Each message, media object, and call is scoped to that `pairId`; the server checks the current pair on every read and write.

## Disconnect and deletion

Disconnect is initiated by either partner. In one transaction, the server marks the pair closed and clears both users' active-pair pointers. New reads, authorized downloads, uploads, and calls must stop working immediately. Media downloads go through an authorization check on every request; a reusable direct S3 presigned download URL would remain valid until it expires. A deletion job removes all messages, media objects, call metadata, and any remaining invite or notification payloads for that pair. It retries until complete and records only a minimal, non-content deletion audit entry. The Android app clears its local message and media cache as soon as it learns the pair is closed.

Deletion should be described precisely to users: content disappears from the app immediately; cloud erasure can take time to finish. Disabling S3 versioning and excluding conversation content from long-lived backups avoids recoverable copies. A recipient can still save a file or screenshot outside the app, which the service cannot erase.

## Proposed AWS architecture

| Need | Service | Responsibility |
| --- | --- | --- |
| Identity | Amazon Cognito User Pools | Email one-time-code sign-in for the first release. Accounts persist after a disconnect. |
| API | API Gateway + AWS Lambda | Authenticate requests and enforce pair ownership. |
| Pairing and messages | DynamoDB | Conditional, transactional writes for one-partner exclusivity; message records partitioned by `pairId`. |
| Live events | API Gateway WebSocket API | Deliver new messages, pair changes, and call invitations while the app is connected. |
| Images and videos | Private S3 bucket | Pair-scoped objects, short-lived upload grants, and downloads gated by the API on every request. |
| Voice and video | LiveKit server on AWS | A call is a temporary two-participant room; the backend issues pair-scoped join tokens and ends the room. |
| Background notifications | Firebase Cloud Messaging | Wake the Android app for messages and incoming calls; push payloads contain no message text by default. |
| Deletion | Lambda + queue/workflow | Revoke access first, then enumerate and remove all pair content with retries. |

The server, never the Android client, issues call credentials. A call can only be joined by the two currently paired users. Calls require microphone/camera permissions and an explicit answer; adding proper incoming-call behavior when the app is closed is part of the Android work. Self-hosted LiveKit needs TLS, open media ports, and TURN configuration on AWS.

## Client choice

**Flutter is selected** for the Android client. LiveKit's maintained Flutter client handles voice/video media; a self-hosted LiveKit server on AWS keeps the call path on the proposed hosting platform. The app and backend still need an incoming-call notification and room-token flow.

## First Android release

- Sign in with email code; set a display name.
- Create, share, redeem, and revoke a single-use invitation.
- A single conversation with chronological text, image, and video messages.
- Upload progress, safe size limits, thumbnail/preview, retry, and offline reconnection.
- Voice and video calling with ringing, accept/decline, mute, camera toggle, hang-up, and connection status.
- Disconnect confirmation and cache clearing on both devices.
- Test on two real Android phones in different countries, including Wi-Fi and cellular networks.

## Engineering checks

- Race test: simultaneous acceptance of two invitations for one account leaves exactly one pair.
- Authorization test: an unpaired user, former partner, or expired invite cannot read old messages or media.
- Disconnect test: both users immediately lose access, all content is eventually erased, and reconnecting starts empty.
- Call test: only the active pair gets meeting credentials; ending/disconnecting stops the call.
- Network test: messages recover after reconnection and do not appear twice.

## First-release assumptions

- Flutter and email verification are selected for the first private test.
- Disconnect erases **both** participants' conversation from the service.
- Limit videos to 100 MB initially; tune this after testing mobile upload reliability and cost.
- Use encryption in transit and at rest. End-to-end encryption is a separate feature and must not be claimed until designed, implemented, and tested.

This document is the product and implementation plan. It does not represent a built or deployed application.
