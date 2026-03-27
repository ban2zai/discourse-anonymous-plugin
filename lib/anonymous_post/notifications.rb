# frozen_string_literal: true

# --- PostAlerter: anonymize notifications for anonymous posts ---

module ::AnonymousPostAlerterExtension
  def create_notification(user, notification_type, post, opts = {})
    if SiteSetting.anonymous_post_enabled && post && AnonymousPostHelper.anon_post?(post)
      anon = AnonymousPostHelper.anonymous_user
      if anon
        opts[:display_username] = anon.username
        opts[:acting_user_id] = anon.id
      else
        opts[:display_username] = AnonymousPostHelper.anon_username
      end
    end
    super(user, notification_type, post, opts)
  end
end

module AnonymousPost
  module Notifications
    def self.apply!(plugin)
      PostAlerter.prepend(AnonymousPostAlerterExtension)

      # --- UserCardSerializer: hide message button for anonymous user ---
      # UserSerializer inherits from UserCardSerializer, so this covers both
      # user card popup and full profile page

      UserCardSerializer.class_eval do
        alias_method :original_can_send_private_message_to_user, :can_send_private_message_to_user
        def can_send_private_message_to_user
          if SiteSetting.anonymous_post_enabled
            anon = AnonymousPostHelper.anonymous_user
            return false if anon && object.id == anon.id
          end
          original_can_send_private_message_to_user
        end
      end

      # --- Flag PM: redirect "send message" for anonymous posts to moderators ---

      plugin.register_post_action_notify_user_handler(Proc.new { |user, post, message|
        if SiteSetting.anonymous_post_enabled &&
           post && AnonymousPostHelper.anon_post_by_id?(post.id) &&
           !AnonymousPostHelper.can_reveal?(Guardian.new(user))

          anon_user = AnonymousPostHelper.anonymous_user
          real_user = post.user
          next nil unless anon_user && real_user  # Allow default if no anon user configured

          title = I18n.t(
            "post_action_types.notify_user.email_title",
            title: post.topic.title,
            locale: SiteSetting.default_locale,
            default: I18n.t("post_action_types.illegal.email_title"),
          )

          body = I18n.t(
            "post_action_types.notify_user.email_body",
            message: message,
            link: "#{Discourse.base_url}#{post.url}",
            locale: SiteSetting.default_locale,
            default: I18n.t("post_action_types.illegal.email_body"),
          )

          truncated_title = title.truncate(SiteSetting.max_topic_title_length, separator: /\s/)

          # 1. PM from sender → anonymous user (sender sees "anonymous" in sent messages)
          PostCreator.create!(
            user,
            archetype: Archetype.private_message,
            subtype: TopicSubtype.notify_user,
            title: truncated_title,
            raw: body,
            target_usernames: anon_user.username,
          )

          # 2. System PM → real user (real user gets the actual message)
          PostCreator.create!(
            Discourse.system_user,
            archetype: Archetype.private_message,
            subtype: TopicSubtype.notify_user,
            title: truncated_title,
            raw: body,
            target_usernames: real_user.username,
          )

          false  # Prevent default PM to real author
        end
      })
    end
  end
end
