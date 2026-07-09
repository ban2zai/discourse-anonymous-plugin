# frozen_string_literal: true

# --- TopicView#recent_posts: anonymize dc:creator in RSS feeds ---
# The RSS template (show.rss.erb) calls rss_creator(post.user) directly,
# bypassing all serializer patches. We wrap anonymous posts in a decorator
# that returns the anonymous user instead, using a single batch DB query.

class ::AnonymousRssPostDecorator < SimpleDelegator
  def initialize(post, anon_user = nil)
    super(post)
    @anon_user = anon_user
  end

  def user
    @anon_user || __getobj__.user
  end

  def cooked
    AnonymousPostHelper.anonymize_cooked_quotes(__getobj__.cooked)
  end
end

module ::AnonymousTopicViewRssExtension
  def recent_posts
    posts = super
    return posts unless SiteSetting.anonymous_post_enabled

    posts_array = posts.to_a
    return posts_array if posts_array.empty?

    anon_post_ids = AnonymousPostHelper.anonymous_author_post_ids(posts_array, topic)
    has_quote_candidates = posts_array.any? { |post| post.cooked.to_s.include?("aside") }

    return posts_array if anon_post_ids.empty? && !has_quote_candidates

    anon_user =
      AnonymousPostHelper.anonymous_user ||
        AnonymousPostHelper.anonymous_user_object

    posts_array.map do |post|
      if anon_post_ids.include?(post.id)
        AnonymousRssPostDecorator.new(post, anon_user)
      elsif post.cooked.to_s.include?("aside")
        AnonymousRssPostDecorator.new(post)
      else
        post
      end
    end
  end
end

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

module AnonymousPost
  module TopicViewExtensions
    def self.apply!(_plugin)
      TopicView.prepend(AnonymousTopicViewRssExtension)
      TopicView.prepend(AnonymousTopicViewExtension)
    end
  end
end
