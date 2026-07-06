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
          if AnonymousPostHelper.hide_real_author?(scope) &&
             scope.user&.id != object.user_id &&
             AnonymousPostHelper.anonymous_author_post?(object)
            AnonymousPostHelper.anon_username
          else
            original_basic_username
          end
        end

        alias_method :original_basic_name, :name
        def name
          return original_basic_name if !SiteSetting.anonymous_post_enabled
          if AnonymousPostHelper.hide_real_author?(scope) &&
             scope.user&.id != object.user_id &&
             AnonymousPostHelper.anonymous_author_post?(object)
            I18n.t("js.anonymous_post.anonymous_name")
          else
            original_basic_name
          end
        end

        alias_method :original_basic_avatar_template, :avatar_template
        def avatar_template
          return original_basic_avatar_template if !SiteSetting.anonymous_post_enabled
          if AnonymousPostHelper.hide_real_author?(scope) &&
             scope.user&.id != object.user_id &&
             AnonymousPostHelper.anonymous_author_post?(object)
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
        if AnonymousPostHelper.hide_real_author?(scope) &&
           scope.user&.id != object.user_id &&
           AnonymousPostHelper.anonymous_author_post?(object)
          I18n.t("js.anonymous_post.anonymous_name")
        else
          object.user&.name
        end
      end

      plugin.add_to_serializer(:post, :user_id) do
        if AnonymousPostHelper.hide_real_author?(scope) &&
           scope.user&.id != object.user_id &&
           AnonymousPostHelper.anonymous_author_post?(object)
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
          return html unless AnonymousPostHelper.hide_real_author?(scope)

          anon_name = AnonymousPostHelper.anon_username
          anon_avatar_url = AnonymousPostHelper.anonymous_avatar_url

          fragment =
            if defined?(Nokogiri::HTML5)
              Nokogiri::HTML5.fragment(html)
            else
              Nokogiri::HTML.fragment(html)
            end
          changed = false

          fragment.css("aside.quote").each do |quote|
            data_username = quote["data-username"]
            data_post = quote["data-post"].to_i
            data_topic = quote["data-topic"].to_i

            next if data_username.blank? || data_post <= 0 || data_topic <= 0

            quoted_post = Post.find_by(topic_id: data_topic, post_number: data_post)
            next unless AnonymousPostHelper.anonymous_author_post?(quoted_post)

            quote["data-username"] = anon_name
            quote["data-user-card"] = anon_name if quote["data-user-card"].present?

            quote.css("[data-user-card]").each do |node|
              node["data-user-card"] = anon_name if node["data-user-card"] == data_username
            end

            title = quote.at_css("div.title")
            if title
              title.traverse do |node|
                next unless node.text?
                node.content = node.content.gsub(data_username, anon_name)
              end

              title.css("img").each do |img|
                img["src"] = anon_avatar_url if img["src"].present?
                img["alt"] = anon_name if img["alt"].present?
                img["title"] = anon_name if img["title"].present?
                img.remove_attribute("srcset")
              end

              title.css("a").each do |link|
                link["href"] = "/u/#{anon_name}" if link["href"].to_s.include?("/u/#{data_username}")
              end
            end

            changed = true
          end

          changed ? fragment.to_html : html
        end
      end

      # --- PostSerializer: anonymize reply-to user for anonymous posts ---

      PostSerializer.class_eval do
        if method_defined?(:raw)
          alias_method :original_anonymous_post_raw, :raw
          def raw
            result = original_anonymous_post_raw
            return result if result.blank?
            return result unless AnonymousPostHelper.hide_real_author?(scope)

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
          if AnonymousPostHelper.hide_real_author?(scope) &&
             AnonymousPostHelper.anonymous_author_post?(post)
            AnonymousPostHelper.anonymous_user&.username || AnonymousPostHelper.anon_username
          else
            original_username
          end
        end

        alias_method :original_display_username, :display_username
        def display_username
          return original_display_username if !SiteSetting.anonymous_post_enabled
          post = Post.find_by(id: object.post_id)
          if AnonymousPostHelper.hide_real_author?(scope) &&
             AnonymousPostHelper.anonymous_author_post?(post)
            AnonymousPostHelper.anonymous_user&.name || I18n.t("js.anonymous_post.anonymous_name")
          else
            original_display_username
          end
        end

        alias_method :original_avatar_template, :avatar_template
        def avatar_template
          return original_avatar_template if !SiteSetting.anonymous_post_enabled
          post = Post.find_by(id: object.post_id)
          if AnonymousPostHelper.hide_real_author?(scope) &&
             AnonymousPostHelper.anonymous_author_post?(post)
            AnonymousPostHelper.anonymous_user&.avatar_template || AnonymousPostHelper::ANON_AVATAR_FALLBACK
          else
            original_avatar_template
          end
        end
      end
    end
  end
end
