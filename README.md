# Aida: one-to-one Android messenger

Aida lets each account have **one active partner**. Either person can disconnect. The server revokes both accounts' access, deletes the pair's conversation and media, and returns both to the invite screen. Pairing again starts an empty conversation.

## Built and verified

- Flutter Android app: Google sign-in UI, name editing, single-use invite codes, text messages, photo/video messages, voice/video call controls, and disconnect confirmation.
- Node 24 API: Google ID-token verification, exclusive pairing in a SQLite transaction, authenticated REST and WebSocket endpoints, private media upload/download (100 MB limit), LiveKit call rooms and pair-scoped join tokens, and pair deletion.
- Backend integration tests for authentication, pairing races, media authorization/deletion, WebSocket delivery, and calls against local LiveKit.
- AWS deployment: Node API, Caddy HTTPS, and self-hosted LiveKit on one Lightsail instance, with persistent chat storage and automatic certificate renewal.

## Version 2.2 (current: 2.2.0, Android version code 5)

- Press and hold a message for quick reactions (❤️ 😂 😮 😢 👍 🔥), Reply, Copy, Keep in Moments, Save to your phone (photos and videos go to an "Aida" album), Share, and, for your own messages, Edit and Delete for both of you. Reactions notify the author; pushes still carry no message text.
- Deleting removes the text or media file from the server and both phones and leaves a "deleted" placeholder. Edits are marked "edited". Kept messages appear in a Kept section in Moments.
- Camera: the camera button in the message field takes a photo with the phone's camera app (hold it to record a video). The "+" sheet offers Camera, Video, and Gallery; Gallery sends up to 10 photos and videos at once. Photos are resized to at most 2560 px before upload.
- Sync: the server numbers every change to an existing message (`updated_seq`), and `GET /v1/messages/changes` lets the app catch up on edits, deletions, reactions, and keeps. Additive migration; disconnect also erases reactions and keeps.

## Version 2.1 (2.1.0, Android version code 4)

- Redesign: the conversation is the home screen, with Moments (days together, next milestone, and every shared photo/video across topics) and Us (partner, theme, accent colour, privacy, account controls) behind the header menu. Warm off-white and muted lavender, Instrument Serif headings, dark mode, and four accent choices (saved per device).
- Replies: swipe a message right, or press and hold for Reply / Copy text / View photo. Replies quote the original; tap the quote to jump to it. The server stores `reply_to_id` (additive migration) and only accepts replies within the same connection and topic. 2.0.1 clients ignore the quote.
- Notifications: no system notification for the conversation already on screen; a topic's notification clears once it is read in the app; the live socket and Firebase no longer alert twice for one message. Background push is configured end to end (Firebase Android app `1:379348658627:android:19659bc8b432dcb5e4f576`, server credential installed on AWS).

## Version 2 (2.0.1, Android version code 3)

- Topic-specific typing indicators over authenticated WebSockets, with throttling and automatic expiry on idle, backgrounding, or disconnect. Draft text is never transmitted as a typing event.
- Online/last-seen status considers foreground devices, with heartbeat expiry for interrupted connections.
- Message receipts: one check = saved by the server; two gray checks = recipient app synced that topic; two green checks = recipient opened that topic at the latest message. Background sync, notifications, and calls do not mark messages read. Both participants need 2.0.1 for activity indicators and receipts.
- Warm cream/green design, new app icon, clearer message bubbles, timestamps, and responsive topic tabs.
- Shared topics (Everyday plus up to 20 named topics). Both partners see the same topics. Existing messages remain in Everyday.
- Dedicated call screen opens immediately when dialing; front-camera preview starts before the other person answers. Automatic media join after answer, ringtone/ringback, camera flip, mute, and speaker controls.
- Android ongoing-call service keeps an established call available when the app is backgrounded.
- Message notifications with inline replies and retry-on-failure; incoming-call notifications with Answer/Decline. Firebase Cloud Messaging is the Android delivery service; all application servers and chat/media storage remain on AWS.
- Notification handlers recheck pairing and authorization before displaying content or sending a reply. A stale notification cannot reply into a new connection. Message text is fetched from AWS instead of being included in the FCM payload.

**Deployment:** The v2 API is deployed at `https://44.209.97.214` on the existing $7/month Lightsail server. Additive database migrations preserve users, sessions, partner links, messages, topics, and media, checked using hashes without exporting their contents. The existing Google Web client ID remains configured.

**Verified for 2.0.1:** The signed APK installed over 2.0.0 with the same certificate and original installation timestamp. On the Android emulator, incoming and outgoing typing work, Everyday typing stays hidden in the Trip tab, and receipt icons update live. A message received in the background advanced delivery without advancing read; reopening the conversation advanced read. Backend tests cover multi-device presence, idle/heartbeat expiry, receipt monotonicity and authorization, topic boundaries, disconnect deletion, and old-database migrations.

**Previously verified on Android:** The dialing self-preview renders, camera video reaches a second client through AWS, camera capture stops after hangup, and a reply typed in an Android notification reaches the correct shared topic. Installing the signed v2 APK over v1 succeeds with the same original installation timestamp, and a secure-storage setting saved by v1 remains unchanged in v2.

**Push status (2.1.0):** both Firebase files are in place and AWS sending is enabled. Delivery with the app swiped away still needs a check on both phones. Normal and forced-relay server media tests previously passed. See the test commands below for the v2 migration, topics, and notification-authorization checks.

### Install as an update

Current signed APK: `build/releases/aida-v2.2.0.apk` (SHA-256 alongside it), also attached to the GitHub release `v2.2.0`.

The package remains `com.yashpatodkar.aida`, and the APK uses the same release signing key as version 1. Its version code is now 5, greater than all previous builds (1–4). **Install the new APK over the old app; do not uninstall, clear storage, or tap Disconnect.** Android preserves the existing secure-storage session and settings, and AWS preserves your pairing and conversation. An expired sign-in session can require signing in again with the same Google account; this does not end the server-side connection.

### Enable background notifications

1. In [Firebase Console](https://console.firebase.google.com/), add Firebase to the existing Aida Google project (project number `379348658627`). Analytics is optional and not required.
2. Add an Android app with package `com.yashpatodkar.aida`; save its download as `android/app/google-services.json` (ignored by Git).
3. In Project settings → Service accounts → Firebase Admin SDK, generate the private key and save it as `deploy/.secrets/firebase-service-account.json` (ignored by Git). Never paste this key into chat or include it in the APK.
4. Run `python3 deploy/enable-push.py`. It validates the project/package, installs the credential on AWS with restricted permissions, and restarts only the API. The credential is mounted read-only and is readable by the Node container user.
5. Rebuild the release APK with the production command below. The Google Services Gradle plugin is applied when the Android configuration file exists; missing configuration leaves background push unavailable rather than breaking sign-in/chat.
6. Allow Aida's notification permission on each phone. Test messages/replies and incoming calls with the recipient on the home screen and after swiping the app away. Android force-stop disables delivery until Aida is opened again; notification permission, silent mode, and Do Not Disturb affect alerts.

The server persists a notification outbox and retries transient failures, removes invalid device tokens, and revokes notification registration when the associated session signs out. Call invitations expire after 60 seconds. Both people should update to v2; v1 can still message but has no topic filtering or background push handling.

## Google sign-in setup

In [Google Cloud Console → Google Auth Platform → Clients](https://console.cloud.google.com/auth/clients), create both clients in the same project:

1. **Android client for local debug:** package `com.yashpatodkar.aida`, SHA-1 `52:45:E2:92:18:A7:89:C4:F0:C6:18:AA:B1:6B:58:6F:54:D7:38:4F`.
2. **Android client for the signed test APK:** same package, SHA-1 `BC:95:08:0E:5C:AA:BA:D8:B1:E7:01:1D:8E:C7:EA:46:CC:D6:15:FA`.
3. **Web application client:** copy its Client ID ending in `.apps.googleusercontent.com`. The Android app passes this as `serverClientId`, and the API uses it as the required ID-token audience. No client secret is used or stored in the app.
4. Configure the consent screen/Branding page. If the app is in testing mode, add both people as test users.

[Google's Android setup guide](https://codelabs.developers.google.com/sign-in-with-google-android) and the [Flutter Android plugin instructions](https://pub.dev/packages/google_sign_in_android) explain the matching package/SHA and Web client IDs.

## Local Android test

Requirements: Flutter, Android SDK/emulator or phone with Google Play Services, Node 24, Docker. On this Mac use the installed Java 24 for Gradle.

Start a local LiveKit development server:

```sh
docker run --rm --name aida-livekit-dev -p 7880:7880 -p 7881:7881 -p 7882:7882/udp livekit/livekit-server --dev --bind 0.0.0.0
```

Start the API in another terminal. Substitute your Web client ID:

```sh
cd server
npm ci
HOST=0.0.0.0 PORT=8080 NODE_ENV=development \
  APP_SECRET=development-secret-at-least-thirty-two-chars \
  GOOGLE_WEB_CLIENT_ID=YOUR_WEB_CLIENT_ID.apps.googleusercontent.com \
  LIVEKIT_PUBLIC_URL=ws://10.0.2.2:7880 \
  LIVEKIT_INTERNAL_URL=ws://127.0.0.1:7880 \
  LIVEKIT_API_KEY=devkey LIVEKIT_API_SECRET=secret \
  npm start
```

Build and install the Android app with the **same** Web client ID:

```sh
cd /Users/yashpatodkar/Documents/aida
JAVA_HOME=/Users/yashpatodkar/Library/Java/JavaVirtualMachines/openjdk-24.0.2/Contents/Home flutter pub get
JAVA_HOME=/Users/yashpatodkar/Library/Java/JavaVirtualMachines/openjdk-24.0.2/Contents/Home flutter build apk --debug --dart-define=GOOGLE_WEB_CLIENT_ID=YOUR_WEB_CLIENT_ID.apps.googleusercontent.com
~/Library/Android/sdk/platform-tools/adb install -r build/app/outputs/flutter-apk/app-debug.apk
```

The emulator reaches the host API at `http://10.0.2.2:8080`. For a physical phone on the same Wi-Fi, set the API address in the app to your computer's LAN address and set `LIVEKIT_PUBLIC_URL` to that address. Cleartext HTTP is permitted in the debug build only. Production needs HTTPS. Sign into a Google account on the emulator first.

Backend tests:

```sh
cd server
npm test
```

Set `LIVEKIT_TEST_URL=ws://127.0.0.1:7880` when the local LiveKit server is running to include the actual call test. The backend retains a development-only email-code endpoint used by test fixtures; production disables it. The Android app uses Google sign-in.

## Inviting your friend

1. Both install the app and sign in with separate Google accounts.
2. You tap **Create invite**, then **Share** or **Copy** to send the 10-character code through a channel you already use.
3. Your friend enters the code, reviews your display name, and taps **Connect**. The code expires after 24 hours, is single-use, and can be revoked.
4. Both stay paired until either taps **Disconnect and delete**. A paired person cannot invite or accept anyone else.

The current invitation is a shareable code, not an Android deep link.

## AWS deployment without owning a domain

All application services run on the same AWS Lightsail instance:

| Setting | Value |
| --- | --- |
| Instance | `aida-test`, Ubuntu 24.04, `us-east-1a` |
| Plan | `micro_3_0`: 1 GB RAM, 2 vCPUs, 40 GB disk, 2 TB bundled transfer, $7/month before tax/overages |
| Static IPv4 | `44.209.97.214` (`aida-test-ip`) |
| API / chat socket | `https://44.209.97.214` / `wss://44.209.97.214/v1/live` |
| LiveKit signaling | `wss://44.209.97.214` |
| Server files | `/opt/aida` |
| Deployment | [deploy/compose.aws.yaml](deploy/compose.aws.yaml) |

The existing AWS instances were stopped; none was reused. No LiveKit Cloud service or paid domain was created. The static IP is attached to this instance. [AWS plan details](https://docs.aws.amazon.com/lightsail/latest/userguide/amazon-lightsail-bundles.html).

Caddy obtains a publicly trusted [Let's Encrypt IP certificate](https://letsencrypt.org/2026/01/15/6day-and-ip-general-availability) and renews it automatically. `aida-turn-cert.timer` checks for a renewed certificate every 15 minutes and refreshes LiveKit's TLS copy. **A certificate change restarts LiveKit and can briefly interrupt an active call.** TURN uses UDP 3478 and TLS 5349; networks permitting only TCP 443 may still prevent calls. HTTPS signaling uses 443. The template is [deploy/Caddyfile.aws.example](deploy/Caddyfile.aws.example).

SSH is restricted to the administrator IP used during deployment. API 8080, LiveKit management 7880, and Caddy admin 2019 are not exposed through the Lightsail firewall. Public media ports are TCP 7881 and UDP 7882, plus TURN. API, Caddy, and LiveKit have memory limits; a 1 GB swap file helps this small test host. This is a private two-person test, not a capacity guarantee for public sign-ups.

### Configured Google clients and Android release build

The user supplied these clients from the same Google project:

- Web: `379348658627-3gsfd82s58bmdnk8e7ae1jcn5hja0m4s.apps.googleusercontent.com`
- Android release: `379348658627-bdpg2cr28a7k9v7t519rdhpr1nuv8un2.apps.googleusercontent.com`

The Web ID is passed as Flutter's `serverClientId` and used as the backend token audience. The Android ID identifies the package/signing registration in Google Console; it is not passed as `serverClientId`. No client secret is needed. Keep both test accounts in the Google Auth Platform audience while testing.

The Web ID is set in both the ignored local `deploy/.secrets/server.env` and the VM's `/opt/aida/deploy/.secrets/server.env`. If it changes, update both and recreate the API with `sudo docker compose -f /opt/aida/deploy/compose.aws.yaml up -d --force-recreate api`.

Build the signed APK using the checked-in public build configuration:

```sh
JAVA_HOME=/Users/yashpatodkar/Library/Java/JavaVirtualMachines/openjdk-24.0.2/Contents/Home \
  flutter build apk --release --dart-define-from-file=config/android-production.json
```

Install the resulting `build/app/outputs/flutter-apk/app-release.apk` on both phones and test from separate networks. Back up `android/key.properties`, `android/app/aida-release.jks`, and the deployment SSH key securely; they are ignored by Git.

### Operations and checks

The SSH key and private configuration are under ignored `deploy/.secrets/`. Connect from the allowed administrator network:

```sh
ssh -i deploy/.secrets/aida-aws \
  -o UserKnownHostsFile=deploy/.secrets/known_hosts ubuntu@44.209.97.214
```

On the server, inspect services with `sudo docker compose -f /opt/aida/deploy/compose.aws.yaml ps`. Check memory with `free -m` and certificate refresh with `sudo systemctl status aida-turn-cert.timer`. If the administrator's public IP changes, update only the SSH firewall CIDR through the AWS console/CLI.

[deploy/verify-media.py](deploy/verify-media.py) sends synthetic audio/video between two clients, verifies receipt in both directions, and deletes its room afterward. Install `livekit` and `livekit-api` in a temporary Python environment. Open a temporary SSH tunnel with `-L 127.0.0.1:17880:127.0.0.1:7880`, then run the script normally and with `--relay`. It reads the ignored local credentials without printing them. The test validates server media transport; it does not replace two-phone Google sign-in/camera/microphone testing.

The API stores SQLite/media on one Docker volume. Keep one API instance for this private release; multiple replicas require shared storage and coordination. No snapshots or chat backups were created. Copies of conversations in backups would undermine permanent erasure. Content is not encrypted end to end, and recipients can retain screenshots or saved files outside the app.

## Protocol and deletion

The app uses **WebSockets for live change notifications** and HTTP(S) for messages, uploads, downloads, and call control. It refreshes on socket events and periodically while open, so temporary socket interruptions do not lose committed messages. LiveKit carries call audio/video.

Pair acceptance is one SQLite transaction that confirms both accounts are unpaired. Each message, media read/write, and call request checks the current pair. Disconnect clears both users' pair, deletes message/media/call records and media files, invalidates old pair access, and closes active LiveKit rooms. Failed filesystem cleanup is retried at server startup. Pairing with the same person again creates a new pair ID and empty history.

## Limits before wider release

- Background message/call notifications require Firebase setup and Android notification permission. Strict phone power policies can delay delivery; force-stopped apps must be reopened.
- Uploads up to 100 MB do not resume after interruption.
- One-server storage, monitoring, backup design, and abuse controls need more work before public sign-up.
- The release key is local and ignored by Git; keep it for all future upgrades. Two-country phone testing remains the final acceptance check.

## Version 2 verification

```sh
# Node 24; includes migration preservation and topic/notification authorization.
cd server
npm test
```

`server/test/upgrade.test.js` recreates a v1 schema with existing users, a pair, session, and message; applies the migration twice; and verifies preservation. `deploy/verify-upgrade.cjs` additionally verified the real AWS records before and after deployment.

```sh
# Debug-only sample UI; excluded from release by kDebugMode.
flutter test --dart-define=AIDA_DESIGN_PREVIEW=true test/design_test.dart
```

The visual test checks the actual chat widget at small screen sizes and larger text. `server/scripts/device-fixture.mjs` and `integration_test/smoke_app.dart` are explicit local test entrypoints with synthetic accounts; the release build uses `lib/main.dart` and never includes a test session. The device fixture listens only on localhost and requires a private LiveKit administration tunnel for call tests.
