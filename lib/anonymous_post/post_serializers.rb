# frozen_string_literal: true

module AnonymousPost
  module PostSerializers
    def self.apply!(plugin)
      # --- BasicPostSerializer: anonymize user fields across ALL post serializers ---
      # Covers PostSerializer, SearchPostSerializer, PostWordpressSerializer

      BasicPostSerializer.class_eval do
        def anonymous_force_mask?
          defined?(::WebHookPostSerializer) && is_a?(::WebHookPostSerializer)
        end

        alias_method :original_basic_username, :username
        def username
          return original_basic_username if !SiteSetting.anonymous_post_enabled
          if AnonymousPostHelper.mask_author?(scope, object, force: anonymous_force_mask?)
            AnonymousPostHelper.anon_username
          else
            original_basic_username
          end
        end

        alias_method :original_basic_name, :name
        def name
          return original_basic_name if !SiteSetting.anonymous_post_enabled
          if AnonymousPostHelper.mask_author?(scope, object, force: anonymous_force_mask?)
            I18n.t("js.anonymous_post.anonymous_name")
          else
            original_basic_name
          end
        end

        alias_method :original_basic_avatar_template, :avatar_template
        def avatar_template
          return original_basic_avatar_template if !SiteSetting.anonymous_post_enabled
          if AnonymousPostHelper.mask_author?(scope, object, force: anonymous_force_mask?)
            AnonymousPostHelper.anonymous_user&.avatar_template || AnonymousPostHelper::ANON_AVATAR_FALLBACK
          else
            original_basic_avatar_template
          end
        end
      end

      # --- PostSerializer-specific overrides ---

      plugin.add_to_serializer(:post, :is_anonymous_post) do
        AnonymousPostHelper.anonymous_post_flag?(object) ? 1 : 0
      end

      plugin.add_to_serializer(:post, :display_username) do
        force_mask = respond_to?(:anonymous_force_mask?) && anonymous_force_mask?
        if AnonymousPostHelper.mask_author?(scope, object, force: force_mask)
          I18n.t("js.anonymous_post.anonymous_name")
        else
          object.user&.name
        end
      end

      plugin.add_to_serializer(:post, :user_id) do
        force_mask = respond_to?(:anonymous_force_mask?) && anonymous_force_mask?
        if AnonymousPostHelper.mask_author?(scope, object, force: force_mask)
          AnonymousPostHelper.anonymous_user_hash[:id]
        else
          object.user_id
        end
      end

      # --- BasicPostSerializer: anonymize quoted usernames in cooked HTML ---
      # NOTE: Using class_eval+alias_method (not add_to_serializer) to avoid Discourse's
      # plugin-enabled gating, which would exclude `cooked` from JSON when plugin is
      # disabled in admin, causing toc-processor.js to crash with undefined.includes().

      BasicPostSerializer.class_eval do
        alias_method :_original_cooked, :cooked
        def cooked
          html = _original_cooked
          return html || "" if html.blank?
          return html unless AnonymousPostHelper.hide_real_author?(scope) || anonymous_force_mask?

          AnonymousPostHelper.anonymize_cooked_quotes(html)
        end
      end

      # --- PostSerializer: anonymize reply-to user for anonymous posts ---

      PostSerializer.class_eval do
        if method_defined?(:raw)
          alias_method :original_anonymous_post_raw, :raw
          def raw
            result = original_anonymous_post_raw
            return result if result.blank?
            return result unless AnonymousPostHelper.hide_real_author?(scope) || anonymous_force_mask?

            AnonymousPostHelper.anonymize_raw_quotes(result)
          end
        end

        alias_method :original_reply_to_user, :reply_to_user
        def reply_to_user
          result = original_reply_to_user
          return result if result.nil?
          return result unless AnonymousPostHelper.hide_real_author?(scope)

          reply_post_number = object.reply_to_post_number
          return result unless reply_post_number

          reply_post = Post.find_by(topic_id: object.topic_id, post_number: reply_post_number)
          if AnonymousPostHelper.anonymous_author_post?(reply_post)
            AnonymousPostHelper.anonymous_user_hash
          else
            result
          end
        end
      end

      # --- PostRevisionSerializer: hide real editor for anonymous posts ---

      PostRevisionSerializer.class_eval do
        alias_method :original_username, :username
        def username
          return original_username if !SiteSetting.anonymous_post_enabled
          post = Post.find_by(id: object.post_id)
          if AnonymousPostHelper.mask_author?(scope, post, exempt_author: false)
            AnonymousPostHelper.anonymous_user&.username || AnonymousPostHelper.anon_username
          else
            original_username
          end
        end

        alias_method :original_display_username, :display_username
        def display_username
          return original_display_username if !SiteSetting.anonymous_post_enabled
          post = Post.find_by(id: object.post_id)
          if AnonymousPostHelper.mask_author?(scope, post, exempt_author: false)
            AnonymousPostHelper.anonymous_user&.name || I18n.t("js.anonymous_post.anonymous_name")
          else
            original_display_username
          end
        end

        alias_method :original_avatar_template, :avatar_template
        def avatar_template
          return original_avatar_template if !SiteSetting.anonymous_post_enabled
          post = Post.find_by(id: object.post_id)
          if AnonymousPostHelper.mask_author?(scope, post, exempt_author: false)
            AnonymousPostHelper.anonymous_user&.avatar_template || AnonymousPostHelper::ANON_AVATAR_FALLBACK
          else
            original_avatar_template
          end
        end
      end
    end
  end
end
