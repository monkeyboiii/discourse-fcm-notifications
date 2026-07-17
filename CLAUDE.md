# discourse-fcm-notifications

APNs push notification bridge for Discourse. Listens for Discourse notification events server-side and delivers them straight to the native iOS app via Apple's APNs HTTP/2 API with `.p8` token auth (Firebase/FCM was removed so push works in mainland China without a VPN).

> **Naming note:** the plugin name, `/fcm_notifications` routes, `fcm_notifications_*` settings, and the `discourse-fcm-notifications` custom-field key are historical — kept for continuity, but nothing here talks to FCM anymore. Client-side pipeline: the iOS repo's `docs/PUSH_NOTIFICATION_MODULE.md`.

## Plugin Workflow

```
Discourse core fires :push_notification event      Any other Notification row is created
  → plugin.rb listener enqueues                      → :notification_created listener (skips the
    Jobs::SendFcmNotifications                         :push_notification set) enqueues
    → Pusher.push(user, payload)                       Jobs::SendFcmNotificationForRow
      builds title/body/routing data                   → Pusher.push_for_notification(notification)

  both → Pusher.send_notification (per registered iOS device)
    → send_apns via apnotic (HTTP/2 + .p8 token auth) to api.push.apple.com
      → device receives APNs push with structured data
```

## File Map

| File | Purpose |
|---|---|
| `plugin.rb` | Entry point. Registers gems (apnotic + net-http2/http-2 for APNs; legacy fcm/googleauth/signet/os/memoist still registered but unused), hooks `:push_notification` and `:notification_created` events, defines two inline jobs |
| `lib/discourse_fcm_notifications/pusher.rb` | Core logic: builds APNs notification (apnotic), manages per-device subscription map, sandbox/production connection pools with BadDeviceToken env retry + self-correction, dead-token cleanup |
| `lib/discourse_fcm_notifications/engine.rb` | Rails engine setup, autoload paths |
| `app/controllers/.../push_controller.rb` | Subscription endpoints: `automatic_subscribe`, `subscribe`, `unsubscribe` |
| `config/routes.rb` | `POST /fcm_notifications/automatic_subscribe` (+ legacy GET, XHR-gated), `POST subscribe/unsubscribe` |
| `config/settings.yml` | Site settings: `enabled`, APNs `key_id`/`team_id`/`p8`/`topic`, plus legacy unused `project_id`/`api_key`/`google_json` |
| `config/locales/server.en.yml` | Notification title translations per type |
| `config/locales/client.en.yml` | UI labels for preferences panel |
| `assets/javascripts/` | Ember component + connector for user preferences notifications tab |

## APNs Custom Payload

The `custom_payload` hash on the APNs notification contains both legacy URL fields and structured routing fields:

**Always present:**
- `linked_obj_type` = `"link"` (static)
- `linked_obj_data` = full URL (e.g. `https://forum.example.com/t/slug/42/7`)

**Routing fields (added by `build_routing_data`):**
- `notification_type` — Discourse integer as string (e.g. `"2"` = replied)
- `topic_id`, `post_number`, `slug` — for post/topic notifications
- `channel_id`, `is_direct_message_channel` — for chat notifications
- `username` — who triggered the notification

All values are strings — kept from the FCM era so the iOS `PushPayloadParser` needed no changes. The `routing_data` merge is nil-safe for `confirm_subscribe` which has no payload.

## Notification Type Routing

| Type | ID | Routing Fields |
|---|---|---|
| mentioned, replied, quoted, edited, liked, posted, linked, group_mentioned, watching_first_post, bookmark_reminder, watching_category_or_tag, private_message | 1-6, 9, 11, 15, 17, 24, 36 | `topic_id`, `post_number`, `slug` |
| chat_mention | 29 | `channel_id` |
| chat_message | 30 | `channel_id`, `is_direct_message_channel` |
| chat_watched_thread | 40 | `channel_id` |
| following, following_created_topic, following_replied | 800-802 | `username` |

**Not routable via push:** `granted_badge` (type 12) — does not fire `:push_notification`, goes through `BadgeGranter` directly.

## Payload Source in Discourse Core

Post/topic payloads originate from `PostAlerter.create_notification_alert` (`app/services/post_alerter.rb`):
```ruby
{ notification_type:, post_number:, topic_title:, topic_id:, excerpt:, username:, post_url:, group_name: }
```

Chat payloads originate from `Chat::NotifyWatching` (`plugins/chat/app/jobs/regular/chat/notify_watching.rb`):
```ruby
{ notification_type:, username:, post_url:, translated_title:, tag:, excerpt:, channel_id:, is_direct_message_channel: }
```

## Device Token Storage

Stored as `user.custom_fields["discourse-fcm-notifications"]` — no migrations, no extra tables. It is a JSON map of `device_id => { token, env, platform, active, seen_at, deactivated_at? }` (multi-device). Legacy shapes (bare token string, or `device_id => token-string`) are still parsed as ios/production/active. Two structural rules, both load-bearing:

- **`normalize_entry` must round-trip every metadata key** (`active`, `seen_at`, `deactivated_at`): the whole map is rewritten through it on *every* save — per-launch subscribe (even unchanged), env self-correction, partial unsubscribe — so a key it drops is silently erased from all slots within one launch of any device.
- **All map writes take `DistributedMutex("fcm_device_map_<user_id>")`** and `devices_map` merges duplicate custom-field rows (Array, last row wins) — `user_custom_fields(user_id, name)` has **no unique index**, so racing writes can create dup rows, which previously read as `{}` and wiped every slot on the next save.

The `automatic_subscribe` endpoint (POST; legacy GET kept for old app builds, gated on `X-Requested-With` against SameSite=Lax cross-site navigation) takes the APNs token plus `device_id`, `environment`, `platform`. `token=REMOVE` deletes the slot ("forget this device" — the app's settings toggle); `token=SUSPEND` deactivates it (the app's sign-out). Not staff-serialized (raw tokens + device ids were leaking into user cards / group members / per-post payloads); inspect via rails console.

## Alert invariant

**The confirmation push fires only when an account gains a device it didn't have** — `Pusher.subscribe` returns true only for a brand-new `device_id`, and the confirm targets only that device. Re-subscribes, token rotations, env changes, and reactivations are silent. Everything else about the slot lifecycle exists to preserve that invariant:

- **Deactivate, don't delete** (`active:false` + `deactivated_at`): used by dead-token cleanup (`Unregistered`), the app's sign-out SUSPEND, and the logto plugin's revocation hook (`revocation_trigger.rb` — web logout-this-device / admin / password change; never expiry, which uses `delete_all` and skips callbacks). Delivery skips inactive slots; the tombstone is what keeps the *next* same-account subscribe silent. Deleting instead re-introduces a confirm push on every reinstall whose token died mid-uninstall.
- **Cross-user token sweep**: registering token T removes T from every other user's map (a physical device belongs to its most recent registrant) — closes the account-switch delivery leak with no client involvement. Runs only when the token actually changed; matches legacy shapes and inactive copies; takes each affected user's mutex.
- **Env self-correction**: delivery retries the opposite APNs host on `BadDeviceToken` and rewrites the stored `env`. `subscribe` therefore keeps the stored env for an unchanged token (the client hint is a build-static guess; the stored value was proven by an APNs accept) — otherwise the hint and the self-correction flip-flop forever, confirm-pushing every session.
- **TTL**: `Jobs::SweepFcmStaleDevices` (daily) prunes slots not seen (active, `seen_at`) or not deactivated (`deactivated_at`) within `Pusher::STALE_DEVICE_TTL` (90 days); untimestamped legacy entries are stamped, not pruned. This is what bounds inactive tombstones — they never reach APNs, so they can never be reported dead.
- **Do NOT hook `:user_logged_out`** — the event carries no device_id; it could only wipe all devices.

## Prometheus metrics

`pusher.rb` emits two low-cardinality counters via `DiscoursePrometheus::InternalMetric::Custom` on the existing `app:9405` collector endpoint:

- `fcm_push_total{result=ok|dead|error, env}` — bumped on each APNs send outcome.
- `fcm_device_subscribe_total{platform, env}` — bumped on a new/changed device registration.

discourse-prometheus prepends `discourse_`, so they surface as `discourse_fcm_*` (the Grafana **DBX Push** / `dbx-push.json` dashboard queries those). No-op when discourse-prometheus isn't loaded; labels never include per-user/token values.

## Site Settings

All under `plugins` category in admin:
- `fcm_notifications_enabled` — master toggle (client-visible for UI component)
- `fcm_notifications_apns_key_id` — APNs auth key ID
- `fcm_notifications_apns_team_id` — Apple Developer team ID
- `fcm_notifications_apns_p8` — APNs `.p8` auth key contents (secret; normalized from however it was pasted and written to `apns_key.p8` at runtime)
- `fcm_notifications_apns_topic` — APNs topic / app bundle ID (default `com.dirtbikex.app`)
- `fcm_notifications_project_id`, `fcm_notifications_api_key`, `fcm_notifications_google_json` — legacy FCM settings, no longer read by any code

## Test Payloads

`test_payloads/*.apns` — ready-to-use APNs payloads for iOS Simulator testing:
```bash
xcrun simctl push booted <BUNDLE_ID> test_payloads/replied_to_post.apns
```

## Known Issues

- APNs `.p8` key file (`apns_key.p8`) written to the working directory at runtime — path not configurable (it is rewritten from the setting on every pool build, so there is no stale-file trap)
- APNs connection pools are memoized in class variables — per-process only; dropped and rebuilt after any delivery exception
- Legacy FCM gems (`fcm`, `googleauth`, `signet`, `os`, `memoist`) are still registered in `plugin.rb` though nothing uses them
- Non-iOS platforms (`platform != "ios"`) are logged and skipped — Android/FCM would need a new sender branch in `send_notification`
- There is no rate limiting (the old inverted `already_sent?` 2-minute limiter was removed entirely)
- The legacy GET `automatic_subscribe` route survives only for pre-POST app builds — remove it (and its XHR gate) once the TestFlight fleet has adopted the POST client
- The legacy web `POST /subscribe` action registers under `device_id="legacy"` (no device_id param); it now gates its confirm on the same new-pairing return as `automatic_subscribe` — the iOS app never calls it
