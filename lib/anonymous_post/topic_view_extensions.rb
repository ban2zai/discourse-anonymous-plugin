# frozen_string_literal: true

module AnonymousPost
  module TopicViewExtensions
    def self.apply!(_plugin)
      # --- TopicView#recent_posts: anonymize dc:creator in RSS feeds ---
      # The RSS template (show.rss.erb) calls rss_creator(post.user) directly,
      # bypassing all serializer patches. We wrap anonymous posts in a decorator
      # that returns the anonymous user instead, using a single batch DB query.

      class ::AnonymousRssPostDecorator < SimpleDelegator
        def initialize(post, anon_user)
          super(post)
          @anon_user = anon_user
        end

        def user
          @anon_user
        end
      end

      module ::AnonymousTopicViewRssExtension
        def recent_posts
          posts = super
          return posts unless SiteSetting.anonymous_post_enabled

          posts_array = posts.to_a
          return posts_array if posts_array.empty?

          post_ids = posts_array.map(&:id)
          anon_post_ids =
            PostCustomField
              .where(post_id: post_ids, name: "is_anonymous_post", value: "1")
              .pluck(:post_id)
              .to_set

          is_anon_topic = AnonymousPostHelper.anon_topic?(topic)
          topic_owner_id = topic.user_id

          return posts_array unless anon_post_ids.any? || is_anon_topic

          anon_user =
            AnonymousPostHelper.anonymous_user ||
              OpenStruct.new(display_name: AnonymousPostHelper.anon_username)

          posts_array.map do |post|
            if anon_post_ids.include?(post.id) || (is_anon_topic && post.user_id == topic_owner_id)
              AnonymousRssPostDecorator.new(post, anon_user)
            else
              post
            end
          end
        end
      end

      TopicView.prepend(AnonymousTopicViewRssExtension)

      # --- TopicView#page_title: anonymize username in browser/crawler <title> tag ---
      # When navigating to a specific post (/t/slug/id/N), Discourse appends
      # "- #N by username" to the page title. This leaks the real author for
      # anonymous posts and anonymous topic owners.

      module ::AnonymousTopicViewExtension
        def page_title
          return super unless SiteSetting.anonymous_post_enabled && @post_number > 1

          post = @topic.posts.find_by(post_number: @post_number)
          return super unless post

          is_anon_post = AnonymousPostHelper.anon_post_by_id?(post.id)
          is_anon_topic_author =
            AnonymousPostHelper.anon_topic?(@topic) && post.user_id == @topic.user_id

          return super unless is_anon_post || is_anon_topic_author

          anon_name = AnonymousPostHelper.anon_username
          title = @topic.title + " - "
          title +=
            if @guardian.can_see_post?(post)
              I18n.t(
                "inline_oneboxer.topic_page_title_post_number_by_user",
                post_number: @post_number,
                username: anon_name,
              )
            else
              I18n.t("inline_oneboxer.topic_page_title_post_number", post_number: @post_number)
            end

          if SiteSetting.topic_page_title_includes_category
            if @topic.category_id != SiteSetting.uncategorized_category_id &&
                 @topic.category_id && @topic.category
              title += " - #{@topic.category.name}"
            elsif SiteSetting.tagging_enabled && visible_tags.exists?
              title +=
                " - #{visible_tags.order("tags.#{Tag.topic_count_column(@guardian)} DESC").first.name}"
            end
          end

          title
        end
      end

      TopicView.prepend(AnonymousTopicViewExtension)
    end
  end
end
