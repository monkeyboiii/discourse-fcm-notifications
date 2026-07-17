# frozen_string_literal: true

require "rails_helper"

describe DiscourseFcmNotifications::PushController do
  fab!(:user)

  let(:token) { "a" * 64 }
  let(:xhr_headers) { { "X-Requested-With" => "XMLHttpRequest" } }

  before { SiteSetting.fcm_notifications_enabled = true }

  describe "#automatic_subscribe" do
    def subscribed_map
      DiscourseFcmNotifications::Pusher.devices_map(user.reload)
    end

    def track_confirm_pushes
      pushes = []
      DiscourseFcmNotifications::Pusher
        .stubs(:send_apns)
        .with { |_token, _env, msg| pushes << msg[:title] }
        .returns([:ok, "production"])
      pushes
    end

    context "when logged out" do
      it "requires login" do
        post "/fcm_notifications/automatic_subscribe.json",
             params: { token: token, device_id: "d1" }

        expect(response.status).to eq(403)
      end
    end

    context "when logged in" do
      before { sign_in(user) }

      it "registers via POST and confirms only the first pairing" do
        pushes = track_confirm_pushes

        2.times do
          post "/fcm_notifications/automatic_subscribe.json",
               params: { token: token, device_id: "d1", environment: "production", platform: "ios" }
          expect(response.status).to eq(200)
        end

        expect(subscribed_map["d1"]["token"]).to eq(token)
        expect(pushes.size).to eq(1)
      end

      it "suspends on SUSPEND and reactivates on re-subscribe without re-confirming" do
        pushes = track_confirm_pushes
        post "/fcm_notifications/automatic_subscribe.json",
             params: { token: token, device_id: "d1", environment: "production", platform: "ios" }

        post "/fcm_notifications/automatic_subscribe.json",
             params: { token: "SUSPEND", device_id: "d1" }
        expect(response.status).to eq(200)
        expect(subscribed_map["d1"]["active"]).to eq(false)

        post "/fcm_notifications/automatic_subscribe.json",
             params: { token: token, device_id: "d1", environment: "production", platform: "ios" }
        expect(subscribed_map["d1"]["active"]).to eq(true)
        expect(pushes.size).to eq(1)
      end

      it "deletes the slot on REMOVE so a re-subscribe confirms again" do
        pushes = track_confirm_pushes
        post "/fcm_notifications/automatic_subscribe.json",
             params: { token: token, device_id: "d1", environment: "production", platform: "ios" }

        post "/fcm_notifications/automatic_subscribe.json",
             params: { token: "REMOVE", device_id: "d1" }
        expect(response.status).to eq(200)
        expect(subscribed_map).to eq({})

        post "/fcm_notifications/automatic_subscribe.json",
             params: { token: token, device_id: "d1", environment: "production", platform: "ios" }
        expect(pushes.size).to eq(2)
      end

      it "still serves pre-POST clients on GET with the XHR header" do
        track_confirm_pushes

        get "/fcm_notifications/automatic_subscribe.json",
            params: { token: token, device_id: "d1", environment: "production", platform: "ios" },
            headers: xhr_headers

        expect(response.status).to eq(200)
        expect(subscribed_map["d1"]["token"]).to eq(token)
      end

      it "rejects a GET without the XHR header (cross-site navigation CSRF)" do
        get "/fcm_notifications/automatic_subscribe.json",
            params: { token: "REMOVE", device_id: "d1" }

        expect(response.status).to eq(403)
      end
    end
  end
end
