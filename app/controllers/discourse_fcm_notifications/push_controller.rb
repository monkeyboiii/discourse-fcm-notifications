module ::DiscourseFcmNotifications
  class PushController < ::ApplicationController
    requires_plugin PLUGIN_NAME

    layout false
    before_action :ensure_logged_in
    before_action :require_xhr_for_get
    skip_before_action :preload_json

    def automatic_subscribe
      device_id = params[:device_id].presence || "legacy"
      case params[:token]
      when "REMOVE"
        DiscourseFcmNotifications::Pusher.unsubscribe(current_user, device_id)
        render json: { success: 'SUCCESS' }
      when "SUSPEND"
        DiscourseFcmNotifications::Pusher.deactivate(current_user, device_id)
        render json: { success: 'SUCCESS' }
      else
        new_device = DiscourseFcmNotifications::Pusher.subscribe(
          current_user,
          params[:token],
          device_id,
          params[:environment],
          params[:platform]
        )
        # Confirm only a brand-new account↔device pairing — re-subscribes, token
        # rotations, and reactivations stay silent (CLAUDE.md § Alert invariant).
        if !new_device
          render json: { success: 'SUCCESS' }
        elsif DiscourseFcmNotifications::Pusher.confirm_subscribe(current_user, device_id)
          render json: { success: 'SUCCESS' }
        else
          render json: { failed: 'FAILED', error: I18n.t("discourse_fcm_notifications.subscribe_error") }
        end
      end
    end
    
    def subscribe
      new_device = DiscourseFcmNotifications::Pusher.subscribe(current_user, params[:subscription])
      if !new_device || DiscourseFcmNotifications::Pusher.confirm_subscribe(current_user, "legacy")
        render json: success_json
      else
        render json: { failed: 'FAILED', error: I18n.t("discourse_fcm_notifications.subscribe_error") }
      end
    end

    def unsubscribe
      DiscourseFcmNotifications::Pusher.unsubscribe(current_user)
      render json: success_json
    end

    private

    # Legacy GET route: the XHR header blocks SameSite=Lax top-level-navigation
    # CSRF until old app builds age out and the GET is removed (POST is the
    # CSRF-protected replacement).
    def require_xhr_for_get
      raise Discourse::InvalidAccess if request.get? && !request.xhr?
    end
  end
end
