module ::DiscourseFcmNotifications
  class PushController < ::ApplicationController
    requires_plugin PLUGIN_NAME

    layout false
    before_action :ensure_logged_in
    skip_before_action :preload_json

    def automatic_subscribe
      device_id = params[:device_id]
      if params[:token] == "REMOVE"
        DiscourseFcmNotifications::Pusher.unsubscribe(current_user, device_id)
        render json: { success: 'SUCCESS' }
      else
        changed = DiscourseFcmNotifications::Pusher.subscribe(current_user, params[:token], device_id)
        # Only send the "subscribed!" confirmation push when this device's token
        # actually changed — the app re-subscribes on every launch, and we don't
        # want to ping the user's devices each time.
        if !changed
          render json: { success: 'SUCCESS' }
        elsif DiscourseFcmNotifications::Pusher.confirm_subscribe(current_user)
          render json: { success: 'SUCCESS' }
        else
          render json: { failed: 'FAILED', error: I18n.t("discourse_fcm_notifications.subscribe_error") }
        end
      end
    end
    
    def subscribe
      if current_user.custom_fields[DiscourseFcmNotifications::PLUGIN_NAME] != params[:subscription]
        DiscourseFcmNotifications::Pusher.subscribe(current_user, params[:subscription])
        if DiscourseFcmNotifications::Pusher.confirm_subscribe(current_user)
          render json: success_json
        else
          render json: { failed: 'FAILED', error: I18n.t("discourse_fcm_notifications.subscribe_error") }
        end
      else
        render json: { failed: 'FAILED', error: I18n.t("discourse_fcm_notifications.the_same") }
      end
    end

    def unsubscribe
      DiscourseFcmNotifications::Pusher.unsubscribe(current_user)
      render json: success_json
    end

  end
end
