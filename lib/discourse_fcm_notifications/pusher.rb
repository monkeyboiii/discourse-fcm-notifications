# frozen_string_literal: true

module ::DiscourseFcmNotifications
  class Pusher
    # Memoized APNs connection pools (per process), one per environment. Reused
    # across Sidekiq jobs so JWT auth tokens aren't regenerated per push.
    @@apns_pool_prod = nil
    @@apns_pool_dev = nil

    def self.push(user, payload)
      message = {
        title: notification_title(
          payload[:notification_type],
          translated_title: payload[:translated_title],
          topic: payload[:topic_title],
          username: payload[:username]
        ),
        message: payload[:excerpt],
        url: "#{Discourse.base_url}/#{payload[:post_url]}",
        routing_data: build_routing_data(payload)
      }
      self.send_notification(user, message)
    end

    # Resolve the banner title for a notification type. Order:
    #   1. a server-localized title carried in the payload (chat sets this)
    #   2. the per-type `popup.<type>` translation
    #   3. a generic `popup.default` fallback — so no type ever shows the raw
    #      "translation missing: …popup.<type>" string on the lock screen.
    def self.notification_title(notification_type, translated_title: nil, topic: nil, username: nil)
      return translated_title if translated_title.present?
      type_name = Notification.types[notification_type]
      I18n.t(
        "discourse_fcm_notifications.popup.#{type_name}",
        site_title: SiteSetting.title,
        topic: topic,
        username: username,
        default: I18n.t("discourse_fcm_notifications.popup.default", site_title: SiteSetting.title)
      )
    end

    def self.confirm_subscribe(user)
      message = {
        title: I18n.t(
          "discourse_fcm_notifications.confirm_title",
          site_title: SiteSetting.title,
        ),
        message: I18n.t("discourse_fcm_notifications.confirm_body"),
        url: "#{Discourse.base_url}"
      }
      self.send_notification(user, message)
    end

    # Push a notification built straight from a `Notification` row. Used by the
    # `:notification_created` listener for types that don't fire `:push_notification`
    # on their own (likes, reactions, new follows, etc.). Routing fields are
    # string-typed to match the iOS `PushPayloadParser`.
    def self.push_for_notification(notification)
      user = notification.user
      return false if user.nil? || user.do_not_disturb?

      data = notification.data_hash || {}
      username = data[:display_username] || data[:username]
      type = notification.notification_type

      routing = { "notification_type" => type.to_s }
      if notification.topic_id
        post_number = notification.post_number || 1
        slug = Topic.where(id: notification.topic_id).pick(:slug)
        routing["topic_id"] = notification.topic_id.to_s
        routing["post_number"] = post_number.to_s
        routing["slug"] = slug if slug.present?
        url = "#{Discourse.base_url}/t/#{slug.presence || '-'}/#{notification.topic_id}/#{post_number}"
      elsif username.present?
        routing["username"] = username
        url = "#{Discourse.base_url}/u/#{username}"
      else
        url = Discourse.base_url
      end

      message = {
        title: notification_title(type, topic: data[:topic_title], username: username),
        message: data[:topic_title] || data[:description] || "",
        url: url,
        routing_data: routing
      }
      self.send_notification(user, message)
    end

    # The user's registered devices as a Hash of device_id => entry, where each
    # entry is { "token" =>, "env" =>, "platform" => }. Tolerates older stored
    # shapes so upgrades are seamless:
    #   - Hash of device_id => entry-hash  (current multi-device format)
    #   - Hash of device_id => token-string (pre-APNs; treated as ios/production)
    #   - String (legacy single-token format)
    #   - nil / blank (no subscription)
    def self.devices_map(user)
      raw = user.custom_fields[DiscourseFcmNotifications::PLUGIN_NAME]
      case raw
      when Hash
        raw.each_with_object({}) do |(device_id, value), acc|
          entry = normalize_entry(value)
          acc[device_id] = entry if entry
        end
      when String
        raw.blank? ? {} : { "legacy" => { "token" => raw, "env" => "production", "platform" => "ios" } }
      else
        {}
      end
    end

    def self.normalize_entry(value)
      if value.is_a?(Hash)
        token = value["token"]
        return nil if token.blank?
        {
          "token" => token,
          "env" => value["env"].presence || "production",
          "platform" => value["platform"].presence || "ios"
        }
      elsif value.is_a?(String) && value.present?
        { "token" => value, "env" => "production", "platform" => "ios" }
      end
    end

    # subscription = device push token (APNs hex for iOS).
    # device_id    = stable per-device id so re-subscribing one device replaces
    #                only its own slot (multi-device safe). Defaults to "legacy".
    # env          = "sandbox" | "production" (APNs host hint, iOS).
    # platform     = "ios" (default) | "android" (future).
    # Returns true when this device's token/env/platform changed (caller uses
    # this to decide whether to send the confirmation push).
    def self.subscribe(user, subscription, device_id = nil, env = nil, platform = nil)
      return false if subscription.blank?
      device_id = device_id.presence || "legacy"
      entry = {
        "token" => subscription,
        "env" => env.presence || "production",
        "platform" => platform.presence || "ios"
      }

      map = devices_map(user)
      previous = map[device_id]
      # Drop stale entries holding this same token under a different device_id
      # (token migrated devices, or a reinstall reissued it).
      map.reject! { |did, e| e["token"] == subscription && did != device_id }
      map[device_id] = entry

      user.custom_fields[DiscourseFcmNotifications::PLUGIN_NAME] = map
      user.save_custom_fields(true)

      changed = previous != entry
      if changed
        record_metric("fcm_device_subscribe_total", "FCM device registrations (new or changed token)", { platform: entry["platform"], env: entry["env"] })
      end
      changed
    end

    # Remove one device's token (device_id given) or every token (device_id nil,
    # e.g. the legacy "REMOVE all" behaviour and the dead-token cleanup fallback).
    def self.unsubscribe(user, device_id = nil)
      if device_id.present?
        map = devices_map(user)
        map.delete(device_id)
        if map.empty?
          user.custom_fields.delete(DiscourseFcmNotifications::PLUGIN_NAME)
        else
          user.custom_fields[DiscourseFcmNotifications::PLUGIN_NAME] = map
        end
      else
        user.custom_fields.delete(DiscourseFcmNotifications::PLUGIN_NAME)
      end
      user.save_custom_fields(true)
    end

    def self.extract_slug_from_post_url(post_url)
      return nil if post_url.blank?
      match = post_url.match(%r{/t/([^/]+)/})
      match[1] if match
    end

    def self.build_routing_data(payload)
      data = {}
      data["notification_type"] = payload[:notification_type].to_s if payload[:notification_type]

      if payload[:channel_id]
        data["channel_id"] = payload[:channel_id].to_s
        data["is_direct_message_channel"] = payload[:is_direct_message_channel].to_s if payload.key?(:is_direct_message_channel)
      end

      if payload[:topic_id]
        data["topic_id"] = payload[:topic_id].to_s
        data["post_number"] = payload[:post_number].to_s if payload[:post_number]
        slug = extract_slug_from_post_url(payload[:post_url])
        data["slug"] = slug if slug
      end

      data["username"] = payload[:username] if payload[:username]
      data
    end

    def self.send_notification(user, message_hash)
      return false unless user && message_hash

      map = devices_map(user)
      if map.empty?
        Rails.logger.info "Push: no device tokens registered for #{user.username}, skipping push about #{message_hash[:title]}"
        return false
      end

      sent_any = false
      dead_device_ids = []

      map.each do |device_id, entry|
        case entry["platform"]
        when "ios"
          result, used_env = send_apns(entry["token"], entry["env"], message_hash)
          case result
          when :ok
            sent_any = true
            record_metric("fcm_push_total", "APNs push send outcomes", { result: "ok", env: used_env })
            Rails.logger.info "APNs: sent '#{message_hash[:title]}' to #{user.username} (device #{device_id}, env #{used_env})"
            # Self-correct a wrong env hint discovered via BadDeviceToken.
            if used_env != entry["env"]
              entry["env"] = used_env
              map[device_id] = entry
              user.custom_fields[DiscourseFcmNotifications::PLUGIN_NAME] = map
              user.save_custom_fields(true)
            end
          when :dead
            record_metric("fcm_push_total", "APNs push send outcomes", { result: "dead", env: entry["env"] })
            Rails.logger.error "APNs: token for #{user.username} (device #{device_id}) is no longer valid; removing it"
            dead_device_ids << device_id
          else
            record_metric("fcm_push_total", "APNs push send outcomes", { result: "error", env: entry["env"] })
            Rails.logger.error "APNs: failed to send to #{user.username} (device #{device_id})"
          end
        else
          # Non-iOS platforms (e.g. Android/FCM) are not implemented. Placeholder
          # branch so adding a sender later is localized to here.
          Rails.logger.info "Push: platform '#{entry["platform"]}' not implemented for #{user.username} (device #{device_id}), skipping"
        end
      end

      dead_device_ids.each { |did| unsubscribe(user, did) }
      sent_any
    end

    # Returns [result, used_env] where result is :ok | :dead | :error.
    # On BadDeviceToken (token belongs to the other APNs environment) retries the
    # opposite host and reports the env that actually worked.
    def self.send_apns(token, env, message_hash)
      env = env.presence || "production"
      response = deliver_apns(token, env, message_hash)
      return [:ok, env] if response&.ok?

      case apns_reason(response)
      when "BadDeviceToken"
        other = (env == "production" ? "sandbox" : "production")
        retry_response = deliver_apns(token, other, message_hash)
        if retry_response&.ok?
          [:ok, other]
        elsif %w[Unregistered BadDeviceToken].include?(apns_reason(retry_response))
          [:dead, env]
        else
          Rails.logger.error "APNs retry error: status=#{retry_response&.status} body=#{retry_response&.body}"
          [:error, env]
        end
      when "Unregistered"
        [:dead, env]
      else
        Rails.logger.error "APNs error: status=#{response&.status} body=#{response&.body}"
        [:error, env]
      end
    end

    def self.apns_reason(response)
      body = response&.body
      body.is_a?(Hash) ? body["reason"] : nil
    end

    def self.deliver_apns(token, env, message_hash)
      apns_pool(env).with do |connection|
        connection.push(build_apns_notification(token, message_hash))
      end
    rescue => e
      Rails.logger.error "APNs delivery exception (env #{env}): #{e.class}: #{e.message}"
      # Drop the memoized pool so a broken connection is rebuilt next time.
      reset_apns_pools
      nil
    end

    def self.build_apns_notification(token, message_hash)
      notification = Apnotic::Notification.new(token)

      alert = { title: message_hash[:title] }
      alert[:body] = message_hash[:message] if message_hash[:message].present?
      notification.alert = alert

      notification.topic = SiteSetting.fcm_notifications_apns_topic
      notification.sound = "default"
      notification.priority = 10
      notification.apns_push_type = "alert" if notification.respond_to?(:apns_push_type=)

      notification.custom_payload = {
        "linked_obj_type" => "link",
        "linked_obj_data" => message_hash[:url]
      }.merge(message_hash[:routing_data] || {})

      notification
    end

    def self.apns_pool(env)
      if env == "sandbox"
        @@apns_pool_dev ||= build_apns_pool(development: true)
      else
        @@apns_pool_prod ||= build_apns_pool(development: false)
      end
    end

    def self.build_apns_pool(development:)
      options = {
        auth_method: :token,
        cert_path: ensure_apns_key_file!,
        key_id: SiteSetting.fcm_notifications_apns_key_id,
        team_id: SiteSetting.fcm_notifications_apns_team_id
      }
      # apnotic requires a block to configure each pooled connection.
      on_connection = proc do |connection|
        connection.on(:error) { |exception| Rails.logger.error "APNs connection error: #{exception}" }
      end
      if development
        Apnotic::ConnectionPool.development(options, { size: 5 }, &on_connection)
      else
        Apnotic::ConnectionPool.new(options, { size: 5 }, &on_connection)
      end
    end

    def self.reset_apns_pools
      @@apns_pool_prod = nil
      @@apns_pool_dev = nil
    end

    # Prometheus counters via discourse-prometheus (InternalMetric::Custom), exposed
    # on the existing app:9405 endpoint — no new infra. Cheap + low-cardinality:
    # labels are bounded (env / platform / result), NEVER per-user or per-token.
    # No-op when discourse-prometheus isn't loaded. Dashboard: the monitoring repo's
    # grafana/dashboards/dbx-push.json.
    def self.record_metric(name, description, labels = {})
      return unless defined?(::DiscoursePrometheus::InternalMetric::Custom) && $prometheus_client
      metric = ::DiscoursePrometheus::InternalMetric::Custom.new
      metric.type = "Counter"
      metric.name = name
      metric.description = description
      metric.labels = labels
      metric.value = 1
      $prometheus_client.send_json(metric.to_h)
    rescue => e
      Rails.logger.warn("discourse-fcm-notifications: metric emit failed: #{e.class}: #{e.message}")
    end

    # Writes the .p8 auth key to a file (apnotic wants a path), mirroring the
    # gcp_key.json pattern. Always (re)writes from the current setting via
    # `normalize_p8`, so correcting the setting takes effect without a stale file.
    def self.ensure_apns_key_file!
      filename = "apns_key.p8"
      raw = SiteSetting.fcm_notifications_apns_p8.to_s
      raise "Error: Missing APNs .p8 auth key for push notifications" if raw.strip.blank?
      # Always (re)write so a corrected setting takes effect (no stale-file trap).
      File.write(filename, normalize_p8(raw))
      filename
    end

    # Rebuild a clean PKCS#8 PEM (Apple .p8 format) from however the key was
    # pasted into the (often single-line) site-setting field — full PEM with real,
    # escaped ("\n"), or space-collapsed newlines, or just the inner base64. We
    # strip the markers + all whitespace down to the base64 body, then re-wrap.
    def self.normalize_p8(raw)
      body = raw.to_s
                .gsub('\n', "\n")
                .gsub(/-----BEGIN[A-Z ]*-----/, "")
                .gsub(/-----END[A-Z ]*-----/, "")
                .gsub(/\s+/, "")
      "-----BEGIN PRIVATE KEY-----\n#{body.scan(/.{1,64}/).join("\n")}\n-----END PRIVATE KEY-----\n"
    end
  end

end
