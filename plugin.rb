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
  end
end
