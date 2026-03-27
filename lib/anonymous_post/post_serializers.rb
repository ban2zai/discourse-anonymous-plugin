# frozen_string_literal: true

module AnonymousPost
  module PostSerializers
    def self.apply!(plugin)
      # --- BasicPostSerializer: anonymize user fields across ALL post serializers ---
      # Covers PostSerializer, SearchPostSerializer, PostWordpressSerializer

      BasicPostSerializer.class_eval do
        alias_method :original_basic_username, :username
        def username
          return original_basic_username if !SiteSetting.anonymous_post_enabled
          if AnonymousPostHelper.anon_post_by_id?(object.id) &&
             !AnonymousPostHelper.can_reveal?(scope) &&
             scope.user&.id != object.user_id
            AnonymousPostHelper.anon_username
          else
            original_basic_username
          end
        end

        alias_method :original_basic_name, :name
        def name
          return original_basic_name if !SiteSetting.anonymous_post_enabled
          if AnonymousPostHelper.anon_post_by_id?(object.id) &&
             !AnonymousPostHelper.can_reveal?(scope) &&
             scope.user&.id != object.user_id
            I18n.t("js.anonymous_post.anonymous_name")
          else
            original_basic_name
          end
        end

        alias_method :original_basic_avatar_template, :avatar_template
        def avatar_template
          return original_basic_avatar_template if !SiteSetting.anonymous_post_enabled
          if AnonymousPostHelper.anon_post_by_id?(object.id) &&
             !AnonymousPostHelper.can_reveal?(scope) &&
             scope.user&.id != object.user_id
            AnonymousPostHelper.anonymous_user&.avatar_template || AnonymousPostHelper::ANON_AVATAR_FALLBACK
          else
            original_basic_avatar_template
          end
        end
      end

      # --- PostSerializer-specific overrides ---

      plugin.add_to_serializer(:post, :is_anonymous_post) do
        object.custom_fields["is_anonymous_post"].to_i
      end

      plugin.add_to_serializer(:post, :display_username) do
        if SiteSetting.anonymous_post_enabled &&
           AnonymousPostHelper.anon_post_by_id?(object.id) &&
           !AnonymousPostHelper.can_reveal?(scope) &&
           scope.user&.id != object.user_id
          I18n.t("js.anonymous_post.anonymous_name")
        else
          object.user&.name
        end
      end

      plugin.add_to_serializer(:post, :user_id) do
        if SiteSetting.anonymous_post_enabled &&
           AnonymousPostHelper.anon_post_by_id?(object.id) &&
           !AnonymousPostHelper.can_reveal?(scope) &&
           scope.user&.id != object.user_id
          AnonymousPostHelper.anonymous_user&.id
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
          return html if !SiteSetting.anonymous_post_enabled
          return html if AnonymousPostHelper.can_reveal?(scope)

          # Anonymize quoted usernames in cooked HTML
          # Quote format: <aside class="quote" data-username="realuser" data-post="N" data-topic="T">
          anon_name = AnonymousPostHelper.anon_username

          html = html.gsub(%r{<aside[^>]*class="quote"[^>]*>.*?</aside>}m) do |quote_block|
            data_username = quote_block[/data-username="([^"]+)"/, 1]
            data_post = quote_block[/data-post="(\d+)"/, 1]
            data_topic = quote_block[/data-topic="(\d+)"/, 1]

            next quote_block unless data_username && data_post && data_topic

            quoted_post = Post.find_by(topic_id: data_topic.to_i, post_number: data_post.to_i)
            if quoted_post && AnonymousPostHelper.anon_post_by_id?(quoted_post.id) &&
               scope.user&.id != quoted_post.user_id
              result = quote_block.gsub(/data-username="[^"]+"/, "data-username=\"#{anon_name}\"")
              result = result.gsub(%r{(<div class="title">\s*<img[^>]*>\s*)#{Regexp.escape(data_username)}(\s*:?\s*</div>)}m) do
                "#{$1}#{anon_name}#{$2}"
              end
              result
            else
              quote_block
            end
          end

          html
        end
      end

      # --- PostSerializer: anonymize reply-to user for anonymous posts ---

      PostSerializer.class_eval do
        alias_method :original_reply_to_user, :reply_to_user
        def reply_to_user
          result = original_reply_to_user
          return result if result.nil?
          return result if !SiteSetting.anonymous_post_enabled
          return result if AnonymousPostHelper.can_reveal?(scope)

          reply_post_number = object.reply_to_post_number
          return result unless reply_post_number

          reply_post = Post.find_by(topic_id: object.topic_id, post_number: reply_post_number)
          if reply_post && AnonymousPostHelper.anon_post_by_id?(reply_post.id) && scope.user&.id != reply_post.user_id
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
          if AnonymousPostHelper.anon_post_by_id?(object.post_id) && !AnonymousPostHelper.can_reveal?(scope)
            AnonymousPostHelper.anonymous_user&.username || AnonymousPostHelper.anon_username
          else
            original_username
          end
        end

        alias_method :original_display_username, :display_username
        def display_username
          return original_display_username if !SiteSetting.anonymous_post_enabled
          if AnonymousPostHelper.anon_post_by_id?(object.post_id) && !AnonymousPostHelper.can_reveal?(scope)
            AnonymousPostHelper.anonymous_user&.name || I18n.t("js.anonymous_post.anonymous_name")
          else
            original_display_username
          end
        end

        alias_method :original_avatar_template, :avatar_template
        def avatar_template
          return original_avatar_template if !SiteSetting.anonymous_post_enabled
          if AnonymousPostHelper.anon_post_by_id?(object.post_id) && !AnonymousPostHelper.can_reveal?(scope)
            AnonymousPostHelper.anonymous_user&.avatar_template || AnonymousPostHelper::ANON_AVATAR_FALLBACK
          else
            original_avatar_template
          end
        end
      end
    end
  end
end
