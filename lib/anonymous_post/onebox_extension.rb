# frozen_string_literal: true

module AnonymousPost
  module OneboxExtension
    def self.apply!(_plugin)
      # --- Oneboxer: anonymize topic preview in composer ---
      # When a link to an anonymous topic is pasted in the editor, Oneboxer renders
      # an HTML preview with the real author's avatar. We override local_topic_html
      # to use the anonymous user instead.
      # OneboxController is also patched to bypass its Redis cache for anonymous
      # topics, ensuring the anonymized version is always served.

      module ::AnonymousOneboxer
        def local_topic_html(url, route, opts)
          return super unless SiteSetting.anonymous_post_enabled

          topic_obj = local_topic(url, route, opts)
          return super unless topic_obj && AnonymousPostHelper.anon_topic?(topic_obj)

          post_number = route[:post_number].to_i
          post =
            if post_number > 1
              topic_obj.posts.where(post_number: post_number).first
            else
              topic_obj.ordered_posts.first
            end

          return super unless post && !post.hidden && allowed_post_types.include?(post.post_type)

          is_anon_post = AnonymousPostHelper.anon_post_by_id?(post.id)
          is_topic_owner_post = post.user_id == topic_obj.user_id

          return super unless is_anon_post || is_topic_owner_post

          anon_name = AnonymousPostHelper.anon_username
          anon_user = AnonymousPostHelper.anonymous_user
          anon_avatar_template = anon_user&.avatar_template || AnonymousPostHelper::ANON_AVATAR_FALLBACK

          if post_number > 1 && opts[:topic_id] == topic_obj.id
            excerpt = post.excerpt(SiteSetting.post_onebox_maxlength, keep_svg: true)
            excerpt.gsub!(/[\r\n]+/, " ")
            excerpt.gsub!("[/quote]", "[quote]")
            quote =
              "[quote=\"#{anon_name}, topic:#{topic_obj.id}, post:#{post.post_number}\"]\n#{excerpt}\n[/quote]"
            PrettyText.cook(quote)
          else
            args = {
              topic_id: topic_obj.id,
              post_number: post.post_number,
              avatar: PrettyText.avatar_img(anon_avatar_template, "tiny"),
              original_url: url,
              title: PrettyText.unescape_emoji(CGI.escapeHTML(topic_obj.title)),
              category_html: CategoryBadge.html_for(topic_obj.category),
              quote:
                PrettyText.unescape_emoji(
                  post.excerpt(SiteSetting.post_onebox_maxlength, keep_svg: true),
                ),
            }
            template_content = send(:template, "discourse_topic_onebox")
            Mustache.render(template_content, args)
          end
        end
      end

      Oneboxer.singleton_class.prepend(AnonymousOneboxer)

      if defined?(OneboxController)
        OneboxController.class_eval do
          before_action :bypass_onebox_cache_for_anonymous_topics, only: :show

          private

          def bypass_onebox_cache_for_anonymous_topics
            return unless SiteSetting.anonymous_post_enabled
            return if params[:url].blank?

            begin
              uri_path = URI.parse(params[:url]).path
              route = Rails.application.routes.recognize_path(uri_path)
              return unless route[:controller] == "topics"
              topic_id = (route[:id] || route[:topic_id]).to_i
              return unless topic_id > 0
              if TopicCustomField.exists?(topic_id: topic_id, name: "is_anonymous_topic", value: "1")
                params[:refresh] = "true"
              end
            rescue StandardError
              # ignore invalid URLs or unrecognized routes
            end
          end
        end
      end
    end
  end
end
