# frozen_string_literal: true

require "net/https"

module ::DiscourseFcmNotifications
  class Pusher
    def self.push(user, payload)
      message = {
        title: I18n.t(
          "discourse_fcm_notifications.popup.#{Notification.types[payload[:notification_type]]}",
          site_title: SiteSetting.title,
          topic: payload[:topic_title],
          username: payload[:username]
        ),
        message: payload[:excerpt],
        url: "#{Discourse.base_url}/#{payload[:post_url]}",
        routing_data: build_routing_data(payload)
      }
      self.send_notification(user, message)
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

    # The user's registered device tokens as a Hash of device_id => token.
    # Tolerates three stored shapes so upgrades are seamless:
    #   - Hash   — current multi-device format
    #   - String — legacy single-token format (pre multi-device)
    #   - nil / blank — no subscription
    def self.tokens_map(user)
      raw = user.custom_fields[DiscourseFcmNotifications::PLUGIN_NAME]
      case raw
      when Hash
        raw.reject { |_, v| v.blank? }
      when String
        raw.blank? ? {} : { "legacy" => raw }
      else
        {}
      end
    end

    # subscription = FCM registration token from the device.
    # device_id    = stable per-device id so re-subscribing one device replaces
    #                only its own token (multi-device safe). Defaults to "legacy"
    #                for old callers that don't send one.
    # Returns true when this device's token is new or changed (caller uses this
    # to decide whether to send the "subscribed!" confirmation push, so the
    # per-launch re-subscribe stays silent).
    def self.subscribe(user, subscription, device_id = nil)
      return false if subscription.blank?
      device_id = device_id.presence || "legacy"

      map = tokens_map(user)
      previous = map[device_id]
      # Drop stale entries holding this same token under a different device_id
      # (token migrated devices, or a reinstall reissued it).
      map.reject! { |did, tok| tok == subscription && did != device_id }
      map[device_id] = subscription

      user.custom_fields[DiscourseFcmNotifications::PLUGIN_NAME] = map
      user.save_custom_fields(true)

      previous != subscription
    end

    # Remove one device's token (device_id given) or every token (device_id nil,
    # e.g. the legacy "REMOVE all" behaviour and the 404 cleanup fallback).
    def self.unsubscribe(user, device_id = nil)
      if device_id.present?
        map = tokens_map(user)
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

      map = tokens_map(user)
      if map.empty?
        Rails.logger.info "FCM: no device tokens registered for #{user.username}, skipping push about #{message_hash[:title]}"
        return false
      end

      ensure_gcp_key!
      fcm = FCM.new(SiteSetting.fcm_notifications_api_key, "gcp_key.json", SiteSetting.fcm_notifications_project_id)

      sent_any = false
      dead_device_ids = []

      map.each do |device_id, token|
        next if token.blank?
        response = fcm.send_v1(build_fcm_message(token, message_hash))

        if response[:response] == 'success'
          Rails.logger.info "FCM: sent '#{message_hash[:title]}' to #{user.username} (device #{device_id})"
          sent_any = true
        elsif response[:status_code] == 404
          Rails.logger.error "FCM: token for #{user.username} (device #{device_id}) is no longer valid; removing it"
          dead_device_ids << device_id
        elsif response[:status_code] == 400
          Rails.logger.error "FCM: malformed message for #{user.username} (device #{device_id}); body: #{response[:body]}"
        else
          Rails.logger.error "FCM: error #{response[:status_code]} for #{user.username} (device #{device_id}); body: #{response[:body]}"
        end
      end

      dead_device_ids.each { |did| unsubscribe(user, did) }
      sent_any
    end

    def self.ensure_gcp_key!
      filename = "gcp_key.json"
      if !File.exist?(filename) && SiteSetting.fcm_notifications_google_json
        File.open(filename, 'w') { |file| file.write(SiteSetting.fcm_notifications_google_json) }
      end
      raise "Error: Missing google json for push notifications" unless File.exist?(filename)
    end

    def self.build_fcm_message(token, message_hash)
      {
        'token': token,
        'data': {
          "linked_obj_type" => 'link',
          "linked_obj_data" => message_hash[:url],
        }.merge(message_hash[:routing_data] || {}),
        'notification': {
          title: message_hash[:title],
          body: message_hash[:message],
        },
        'android': {
          "priority": "normal",
        },
        'apns': {
          headers: {
            "apns-priority": "5"
          },
          payload: {
            aps: {
              "category": "#{Time.zone.now.to_i}",
              "sound": "default",
              "interruption-level": "active"
            }
          },
        },
        'fcm_options': {
          "analytics_label": "Label"
        }
      }
    end
  end

end
