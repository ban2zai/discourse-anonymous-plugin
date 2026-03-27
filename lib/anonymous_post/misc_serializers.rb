# frozen_string_literal: true

# --- UserSearch: hide topic owner from @mention autocomplete in anonymous topics ---
# When typing @ in an anonymous topic with empty term, Discourse returns recent
# participants. The topic owner would appear, revealing their identity.

module ::AnonymousUserSearchExtension
  def search
    results = super
    return results unless SiteSetting.anonymous_post_enabled
    return results unless @topic_id

    topic = @topic || Topic.find_by(id: @topic_id)
    return results unless topic && AnonymousPostHelper.anon_topic?(topic)

    results.to_a.reject { |u| u.id == topic.user_id }
  end
end

module AnonymousPost
  module MiscSerializers
    def self.apply!(_plugin)
      UserSearch.prepend(AnonymousUserSearchExtension)

      # --- Bookmark serializers: hide real author in /u/[user]/activity/bookmarks ---
      # UserBookmarkBaseSerializer#user calls bookmarkable_user and serializes it via
      # BasicUserSerializer. For topic bookmarks this returns first_post.user (topic
      # creator), for post bookmarks it returns post.user — both leak the real author.

      if defined?(UserTopicBookmarkSerializer)
        UserTopicBookmarkSerializer.class_eval do
          def bookmarkable_user
            original = first_post.user
            return original unless SiteSetting.anonymous_post_enabled
            return original if AnonymousPostHelper.can_reveal?(scope)
            return original unless AnonymousPostHelper.anon_topic?(topic)
            return original if scope.user&.id == topic.user_id
            AnonymousPostHelper.anonymous_user_object
          end
        end
      end

      if defined?(UserPostBookmarkSerializer)
        UserPostBookmarkSerializer.class_eval do
          def bookmarkable_user
            post_obj = post
            original = post_obj.user
            return original unless SiteSetting.anonymous_post_enabled
            return original if AnonymousPostHelper.can_reveal?(scope)
            return original if scope.user&.id == post_obj.user_id

            if AnonymousPostHelper.anon_post_by_id?(post_obj.id)
              return AnonymousPostHelper.anonymous_user_object
            end

            topic_obj = topic
            if AnonymousPostHelper.anon_topic?(topic_obj) && post_obj.user_id == topic_obj.user_id
              return AnonymousPostHelper.anonymous_user_object
            end

            original
          end
        end
      end
    end
  end
end
