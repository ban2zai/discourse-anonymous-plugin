# frozen_string_literal: true

# --- TopicView#recent_posts: anonymize dc:creator in RSS feeds ---
# The RSS template (show.rss.erb) calls rss_creator(post.user) directly,
# bypassing all serializer patches. We wrap anonymous posts in a decorator
# that returns the anonymous user instead, using a single batch DB query.

class ::AnonymousPostUserDecorator < SimpleDelegator
  def initialize(post, anon_user = nil)
    super(post)
    @anon_user = anon_user
  end

  def user
    @anon_user || __getobj__.user
  end
end

class ::AnonymousRssPostDecorator < AnonymousPostUserDecorator
  def cooked
    AnonymousPostHelper.anonymize_cooked_quotes(__getobj__.cooked)
  end
end

module ::AnonymousTopicViewRssExtension
  def recent_posts
    posts = super
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
  def links
    @anonymous_post_links ||= links_with_safe_attribution(super)
  end

  def page_title
    return super unless @post_number > 1

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

  private

  def links_with_safe_attribution(links)
    return links if links.blank? || AnonymousPostHelper.can_reveal?(@guardian)

    viewer_id = @guardian.user&.id
    user_ids = links.filter_map { |link| link.user_id unless link.user_id == viewer_id }
    return links if user_ids.empty?

    stored_links = TopicLink.where(topic_id: @topic.id, url: links.map(&:url), user_id: user_ids).to_a
    links_by_key = stored_links.group_by { |link| attribution_key(link) }
    post_ids = stored_links.filter_map { |link| attribution_post_id(link) }
    posts = Post.with_deleted.where(id: post_ids).select(:id, :user_id, :topic_id).index_by(&:id)
    anonymous_ids = AnonymousPostHelper.anonymous_author_post_ids(posts.values)

    links.map do |link|
      next link if link.user_id.nil? || link.user_id == viewer_id

      sources = links_by_key[attribution_key(link)]
      omit_user_id = sources.blank? ||
        sources.any? do |source|
          post = posts[attribution_post_id(source)]
          !post || post.user_id != source.user_id || anonymous_ids.include?(post.id)
        end
      if omit_user_id
        link.dup.tap { |result| result.user_id = nil }
      else
        link
      end
    end
  end

  def attribution_key(link)
    [link.url, link.user_id, link.reflection, link.internal, link.domain, link.link_topic_id]
  end

  def attribution_post_id(link)
    link.reflection ? link.link_post_id : link.post_id
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
