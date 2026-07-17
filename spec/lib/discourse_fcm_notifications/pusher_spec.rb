# frozen_string_literal: true

require "rails_helper"

describe DiscourseFcmNotifications::Pusher do
  fab!(:user)

  let(:field_name) { DiscourseFcmNotifications::PLUGIN_NAME }
  let(:token) { "a" * 64 }
  let(:other_token) { "b" * 64 }
  let(:message) { { title: "hello", message: "body", url: "https://example.com" } }

  def slot(owner, device_id)
    described_class.devices_map(owner.reload)[device_id]
  end

  describe ".subscribe" do
    it "returns true only for a new device_id and stamps active/seen_at" do
      expect(described_class.subscribe(user, token, "device-1", "production", "ios")).to eq(true)

      entry = slot(user, "device-1")
      expect(entry["token"]).to eq(token)
      expect(entry["active"]).to eq(true)
      expect(entry["seen_at"]).to be_present

      expect(described_class.subscribe(user, token, "device-1", "production", "ios")).to eq(false)
    end

    it "updates a token rotation on a known device silently" do
      described_class.subscribe(user, token, "device-1", "production", "ios")

      expect(described_class.subscribe(user, other_token, "device-1", "production", "ios")).to eq(false)
      expect(slot(user, "device-1")["token"]).to eq(other_token)
    end

    it "keeps the stored env when the token is unchanged (env follows the token)" do
      described_class.subscribe(user, token, "device-1", "production", "ios")
      described_class.update_device_env(user, "device-1", "sandbox")

      expect(described_class.subscribe(user, token, "device-1", "production", "ios")).to eq(false)
      expect(slot(user, "device-1")["env"]).to eq("sandbox")
    end

    it "takes the client env hint when the token changed" do
      described_class.subscribe(user, token, "device-1", "sandbox", "ios")
      described_class.subscribe(user, other_token, "device-1", "production", "ios")

      expect(slot(user, "device-1")["env"]).to eq("production")
    end

    it "reactivates a suspended slot silently and drops the tombstone timestamp" do
      described_class.subscribe(user, token, "device-1", "production", "ios")
      described_class.deactivate(user, "device-1")

      expect(described_class.subscribe(user, token, "device-1", "production", "ios")).to eq(false)

      entry = slot(user, "device-1")
      expect(entry["active"]).to eq(true)
      expect(entry["deactivated_at"]).to be_nil
    end

    it "drops this user's other device_ids holding the same token" do
      described_class.subscribe(user, token, "old-install", "production", "ios")
      described_class.subscribe(user, token, "new-install", "production", "ios")

      expect(described_class.devices_map(user.reload).keys).to contain_exactly("new-install")
    end

    it "removes the token from other users' maps (device follows its registrant)" do
      other_user = Fabricate(:user)
      described_class.subscribe(other_user, token, "device-1", "production", "ios")

      described_class.subscribe(user, token, "device-1", "production", "ios")

      expect(described_class.devices_map(other_user.reload)).to eq({})
      expect(UserCustomField.exists?(user_id: other_user.id, name: field_name)).to eq(false)
      expect(slot(user, "device-1")["token"]).to eq(token)
    end

    it "sweeps a legacy bare-string subscription holding the token" do
      other_user = Fabricate(:user)
      other_user.custom_fields[field_name] = token
      other_user.save_custom_fields(true)

      described_class.subscribe(user, token, "device-1", "production", "ios")

      expect(described_class.devices_map(other_user.reload)).to eq({})
    end

    it "sweeps a legacy device_id=>string entry holding the token" do
      other_user = Fabricate(:user)
      other_user.custom_fields[field_name] = { "old-device" => token }
      other_user.save_custom_fields(true)

      described_class.subscribe(user, token, "device-1", "production", "ios")

      expect(described_class.devices_map(other_user.reload)).to eq({})
    end

    it "sweeps another user's INACTIVE tombstone holding the token" do
      other_user = Fabricate(:user)
      described_class.subscribe(other_user, token, "device-1", "production", "ios")
      described_class.deactivate(other_user, "device-1")

      described_class.subscribe(user, token, "device-1", "production", "ios")

      expect(described_class.devices_map(other_user.reload)).to eq({})
    end

    it "preserves a sibling slot's tombstone across an unchanged re-subscribe" do
      described_class.subscribe(user, token, "device-1", "production", "ios")
      described_class.subscribe(user, other_token, "device-2", "production", "ios")
      described_class.deactivate(user, "device-2")

      described_class.subscribe(user, token, "device-1", "production", "ios")

      entry = slot(user, "device-2")
      expect(entry["active"]).to eq(false)
      expect(entry["deactivated_at"]).to be_present
    end
  end

  describe ".deactivate" do
    it "tombstones the slot so delivery skips it" do
      described_class.subscribe(user, token, "device-1", "production", "ios")

      described_class.deactivate(user, "device-1")

      entry = slot(user, "device-1")
      expect(entry["active"]).to eq(false)
      expect(entry["deactivated_at"]).to be_present
      expect(described_class.send_notification(user, message)).to eq(false)
    end
  end

  describe ".devices_map" do
    it "normalizes legacy shapes and defaults them active" do
      user.custom_fields[field_name] = { "old-device" => token }
      user.save_custom_fields(true)

      entry = slot(user, "old-device")
      expect(entry["active"]).to eq(true)
      expect(entry["env"]).to eq("production")
    end

    it "merges duplicate custom-field rows, last row winning" do
      value = { "d1" => { "token" => token, "env" => "production", "platform" => "ios" } }
      UserCustomField.create!(user_id: user.id, name: field_name, value: value.to_json)
      value["d1"]["token"] = other_token
      UserCustomField.create!(user_id: user.id, name: field_name, value: value.to_json)

      map = described_class.devices_map(user.reload)
      expect(map["d1"]["token"]).to eq(other_token)
    end
  end

  describe ".send_notification" do
    it "targets only the given device when only_device_id is passed" do
      described_class.subscribe(user, token, "device-1", "production", "ios")
      described_class.subscribe(user, other_token, "device-2", "production", "ios")

      pushed_tokens = []
      described_class
        .stubs(:send_apns)
        .with { |apns_token, _env, _msg| pushed_tokens << apns_token }
        .returns([:ok, "production"])

      described_class.send_notification(user, message, only_device_id: "device-2")

      expect(pushed_tokens).to contain_exactly(other_token)
    end

    it "deactivates (not deletes) a dead token's slot" do
      described_class.subscribe(user, token, "device-1", "production", "ios")
      described_class.stubs(:send_apns).returns([:dead, "production"])

      described_class.send_notification(user, message)

      entry = slot(user, "device-1")
      expect(entry["active"]).to eq(false)
    end

    it "self-corrects env without dropping inactive slots from the map" do
      described_class.subscribe(user, token, "device-1", "sandbox", "ios")
      described_class.subscribe(user, other_token, "device-2", "production", "ios")
      described_class.deactivate(user, "device-2")
      described_class.stubs(:send_apns).returns([:ok, "production"])

      described_class.send_notification(user, message)

      map = described_class.devices_map(user.reload)
      expect(map["device-1"]["env"]).to eq("production")
      expect(map["device-2"]["active"]).to eq(false)
    end
  end

  describe ".sweep_stale_devices" do
    it "prunes slots past the TTL and keeps fresh ones" do
      freeze_time
      described_class.subscribe(user, token, "stale", "production", "ios")

      freeze_time(91.days.from_now)
      described_class.subscribe(user, other_token, "fresh", "production", "ios")
      described_class.sweep_stale_devices

      expect(described_class.devices_map(user.reload).keys).to contain_exactly("fresh")
    end

    it "ages inactive slots on deactivated_at and deletes an emptied row" do
      freeze_time
      described_class.subscribe(user, token, "gone", "production", "ios")
      described_class.deactivate(user, "gone")

      freeze_time(91.days.from_now)
      described_class.sweep_stale_devices

      expect(UserCustomField.exists?(user_id: user.id, name: field_name)).to eq(false)
    end

    it "stamps untimestamped legacy entries instead of pruning them" do
      user.custom_fields[field_name] = { "old-device" => token }
      user.save_custom_fields(true)

      described_class.sweep_stale_devices

      entry = slot(user, "old-device")
      expect(entry).to be_present
      expect(entry["seen_at"]).to be_present
    end
  end
end
