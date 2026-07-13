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
| `config/routes.rb` | `GET /fcm_notifications/automatic_subscribe`, `POST subscribe/unsubscribe` |
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

Stored as `user.custom_fields["discourse-fcm-notifications"]` — no migrations, no extra tables. It is a JSON map of `device_id => { token, env, platform }` (multi-device; a dead token removes only its own slot). Legacy shapes (bare token string, or `device_id => token-string`) are still parsed as ios/production. The `automatic_subscribe` endpoint is what native apps call with their APNs device token plus `device_id`, `environment` (`sandbox`/`production`), and `platform`; `token=REMOVE` unsubscribes, and the confirmation push is sent only when the device's entry actually changed.

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
