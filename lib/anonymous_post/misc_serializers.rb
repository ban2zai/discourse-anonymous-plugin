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

      # --- UserActionSerializer: anonymize post author in likes-given stream ---
      # When a user likes an anonymous post, the likes-given activity tab
      # (/u/[user]/activity/likes-given) serializes the post author's username,
      # name, avatar_template, and user_id — leaking the real identity.
      # We replace those fields with anonymous user data when the liked post is
      # anonymous and the viewer is not the post author themselves.

      UserActionSerializer.class_eval do
        alias_method :_orig_ua_username, :username
        def username
          _anon_ua_author[:username] || _orig_ua_username
        end

        alias_method :_orig_ua_name, :name
        def name
          _anon_ua_author[:name] || _orig_ua_name
        end

        alias_method :_orig_ua_avatar_template, :avatar_template
        def avatar_template
          _anon_ua_author[:avatar_template] || _orig_ua_avatar_template
        end

        alias_method :_orig_ua_user_id, :user_id
        def user_id
          _anon_ua_author[:user_id] || _orig_ua_user_id
        end

        private

        # Returns a hash with anonymized author fields when the action's post is anonymous
        # and the viewer is not the post author. Returns an empty hash otherwise, so each
        # method falls through to the aliased original.
        def _anon_ua_author
          return @_anon_ua_author if defined?(@_anon_ua_author)
          @_anon_ua_author = _compute_anon_ua_author
        end

        def _compute_anon_ua_author
          return {} unless SiteSetting.anonymous_post_enabled
          return {} if AnonymousPostHelper.can_reveal?(scope)

          post_id = (object.try(:post_id) || object.try(:target_post_id)).to_i
          return {} unless post_id.positive?
          return {} unless AnonymousPostHelper.anon_post_by_id?(post_id)

          # Don't anonymize when the viewer is the post author (e.g. WAS_LIKED on own post)
          return {} if scope.user&.id == object.try(:user_id).to_i

          anon = AnonymousPostHelper.anonymous_user_hash
          {
            username:        anon[:username],
            name:            anon[:name],
            avatar_template: anon[:avatar_template],
            user_id:         anon[:id],
          }
        end
      end
    end
  end
end
