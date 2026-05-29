# frozen_string_literal: true

# name: discourse-fcm-notifications
# about: Plugin for integrating firebase notifications to a custom app
# version: 0.2.0
# authors: Judith Meyer, Jeff Wong (original plugin: discourse-pushover-notifications)
# url: https://github.com/sprachprofi/discourse-fcm-notifications

enabled_site_setting :fcm_notifications_enabled
gem 'signet', '0.17.0'
gem 'os', '1.1.4'
gem 'memoist', '0.16.2'
gem 'googleauth', '1.7.0'
gem 'fcm', '1.0.8'
# Direct APNs delivery (HTTP/2 + .p8 token auth) — the iOS push path that bypasses
# FCM/Google entirely so token registration works in China without a VPN. Discourse
# installs plugin gems with --ignore-dependencies, so apnotic's deps are listed
# explicitly, deepest-first. connection_pool (apnotic's other dep) ships with core.
# http-2's load path is `http/2`, not its gem name — set require_name accordingly.
gem 'http-2', '1.1.3', require_name: 'http/2'
gem 'net-http2', '0.19.0'
gem 'apnotic', '1.7.0'

module ::DiscourseFcmNotifications
  PLUGIN_NAME = "discourse-fcm-notifications"
  #autoload :Pusher, "#{Rails.root}/plugins/discourse-fcm-notifications/services/discourse_fcm_notifications/pusher"
end

require_relative "lib/discourse_fcm_notifications/engine"

after_initialize do
  User.register_custom_field_type(DiscourseFcmNotifications::PLUGIN_NAME, :json)
  allow_staff_user_custom_field DiscourseFcmNotifications::PLUGIN_NAME

  DiscourseEvent.on(:push_notification) do |user, payload|
    if SiteSetting.fcm_notifications_enabled?
      Jobs.enqueue(:send_fcm_notifications, user_id: user.id, payload: payload)
    end
  end

  # Notification types that ALREADY fire `:push_notification` (handled above), so the
  # `:notification_created` listener below must skip them to avoid double-pushing:
  #   - core NOTIFIABLE_TYPES
  #   - chat types (chat plugin's NotifyWatching / NotifyMentioned)
  #   - following_created_topic/replied (discourse-follow alerts directly)
  #   - assigned (discourse-assign), question_answer_user_commented (discourse-post-voting)
  fcm_already_pushed_types =
    (
      PostAlerter::NOTIFIABLE_TYPES +
        Notification.types.values_at(
          :chat_mention, :chat_message, :chat_invitation,
          :chat_group_mention, :chat_quoted, :chat_watched_thread,
          :following_created_topic, :following_replied,
          :assigned, :question_answer_user_commented
        ).compact
    ).to_set

  # Broaden coverage: every other notification ROW (likes, reactions, new follows,
  # bookmark reminders, badges, …) pushes via this listener. The token-presence guard
  # avoids enqueuing jobs for users without a registered device.
  DiscourseEvent.on(:notification_created) do |notification|
    next unless SiteSetting.fcm_notifications_enabled?
    next if fcm_already_pushed_types.include?(notification.notification_type)
    next unless UserCustomField.where(
      user_id: notification.user_id,
      name: DiscourseFcmNotifications::PLUGIN_NAME
    ).exists?
    Jobs.enqueue(:send_fcm_notification_for_row, notification_id: notification.id)
  end

  #DiscourseEvent.on(:user_logged_out) do |user|
  #  if SiteSetting.fcm_notifications_enabled?
  #    DiscourseFcmNotifications::Pusher.unsubscribe(user)
  #    user.save_custom_fields(true)
  #  end
  #end

  require_dependency 'jobs/base'
  module ::Jobs
    class SendFcmNotifications < ::Jobs::Base
      def execute(args)
        return unless SiteSetting.fcm_notifications_enabled?

        user = User.find(args[:user_id])
        DiscourseFcmNotifications::Pusher.push(user, args[:payload])
      end
    end

    class SendFcmNotificationForRow < ::Jobs::Base
      def execute(args)
        return unless SiteSetting.fcm_notifications_enabled?

        notification = Notification.find_by(id: args[:notification_id])
        return if notification.nil?
        DiscourseFcmNotifications::Pusher.push_for_notification(notification)
      end
    end
  end
end
