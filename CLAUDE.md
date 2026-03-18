# discourse-fcm-notifications

Firebase Cloud Messaging push notification bridge for Discourse. Listens for Discourse notification events server-side and delivers them to native iOS/Android apps via FCM.

## Plugin Workflow

```
Discourse core fires :push_notification event
  → plugin.rb listener enqueues Jobs::SendFcmNotifications
    → Pusher.push(user, payload) builds title/body/routing data
      → Pusher.send_notification sends via FCM v1 API
        → Device receives APNs/Android push with structured data
```

## File Map

| File | Purpose |
|---|---|
| `plugin.rb` | Entry point. Registers gems (fcm, googleauth, signet), hooks `:push_notification` event, defines inline job |
| `lib/discourse_fcm_notifications/pusher.rb` | Core logic: builds FCM message, manages subscriptions, rate-limits (2-min per token) |
| `lib/discourse_fcm_notifications/engine.rb` | Rails engine setup, autoload paths |
| `app/controllers/.../push_controller.rb` | Subscription endpoints: `automatic_subscribe`, `subscribe`, `unsubscribe` |
| `config/routes.rb` | `GET /fcm_notifications/automatic_subscribe`, `POST subscribe/unsubscribe` |
| `config/settings.yml` | Site settings: `enabled`, `project_id`, `api_key`, `google_json` |
| `config/locales/server.en.yml` | Notification title translations per type |
| `config/locales/client.en.yml` | UI labels for preferences panel |
| `assets/javascripts/` | Ember component + connector for user preferences notifications tab |

## FCM Data Payload

The `data` hash sent to FCM contains both legacy URL fields and structured routing fields:

**Always present:**
- `linked_obj_type` = `"link"` (static)
- `linked_obj_data` = full URL (e.g. `https://forum.example.com/t/slug/42/7`)

**Routing fields (added by `build_routing_data`):**
- `notification_type` — Discourse integer as string (e.g. `"2"` = replied)
- `topic_id`, `post_number`, `slug` — for post/topic notifications
- `channel_id`, `is_direct_message_channel` — for chat notifications
- `username` — who triggered the notification

All `data` values are strings (FCM requirement). The `routing_data` merge is nil-safe for `confirm_subscribe` which has no payload.

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

Stored as `user.custom_fields["discourse-fcm-notifications"]` — no migrations, no extra tables. The `automatic_subscribe` endpoint is what native apps call with their FCM device token.

## Site Settings

All under `plugins` category in admin:
- `fcm_notifications_enabled` — master toggle (client-visible for UI component)
- `fcm_notifications_project_id` — GCP project ID
- `fcm_notifications_api_key` — FCM API key
- `fcm_notifications_google_json` — full GCP service account JSON (written to `gcp_key.json` at runtime)

## Test Payloads

`test_payloads/*.apns` — ready-to-use APNs payloads for iOS Simulator testing:
```bash
xcrun simctl push booted <BUNDLE_ID> test_payloads/replied_to_post.apns
```

## Known Issues

- `already_sent?` rate-limit condition is inverted: `@@last_time < 2.minutes.ago` means "last time was MORE than 2 minutes ago", opposite of the comment's intent
- GCP key file written to working directory at runtime — path not configurable
- Rate limiting uses class variables — not safe across multiple processes/threads
