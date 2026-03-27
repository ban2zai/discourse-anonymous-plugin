# frozen_string_literal: true

module AnonymousPost
  module PostCreationHandler
    def self.handle(post, opts)
      return unless SiteSetting.anonymous_post_enabled
      value = opts[:is_anonymous_post].to_i
      return unless value.positive?

      topic = post.topic
      allowed = false

      if post.post_number == 1
        # New topic — check category whitelist (empty = disabled)
        allowed = AnonymousPostHelper.category_allowed?(topic.category_id)
      else
        # Reply — only topic owner in their own anonymous topic
        allowed = AnonymousPostHelper.anon_topic?(topic) && post.user_id == topic.user_id
      end

      if allowed
        post.custom_fields["is_anonymous_post"] = value
        post.save_custom_fields(true)

        if post.post_number == 1
          topic.custom_fields["is_anonymous_topic"] = 1
          topic.save_custom_fields(true)
        end
      end
    end
  end
end
