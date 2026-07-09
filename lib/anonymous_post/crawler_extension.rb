# frozen_string_literal: true

class ::AnonymousCrawlerPostDecorator < SimpleDelegator
  def initialize(post, anon_user = nil)
    super(post)
    @anon_user = anon_user
  end

  def user
    @anon_user || __getobj__.user
  end

  def user_id
    @anon_user ? AnonymousPostHelper.anonymous_user_hash[:id] : __getobj__.user_id
  end

  def cooked
    AnonymousPostHelper.anonymize_cooked_quotes(__getobj__.cooked)
  end

  def is_a?(klass)
    super || __getobj__.is_a?(klass)
  end
  alias kind_of? is_a?

  def class
    __getobj__.class
  end
end

module ::AnonymousCrawlerTopicViewExtension
  def enable_anonymous_crawler_mask!
    @anonymous_crawler_mask = true
  end

  def anonymous_crawler_mask?
    @anonymous_crawler_mask
  end

  def posts
    result = super
    return result unless SiteSetting.anonymous_post_enabled && anonymous_crawler_mask?

    posts_array = result.to_a
    return result if posts_array.empty?

    anon_post_ids = AnonymousPostHelper.anonymous_author_post_ids(posts_array, topic)
    has_quote_candidates = posts_array.any? { |post| post.cooked.to_s.include?("aside") }
    return result if anon_post_ids.empty? && !has_quote_candidates

    anon_user = AnonymousPostHelper.anonymous_user || AnonymousPostHelper.anonymous_user_object

    posts_array.map do |post|
      if anon_post_ids.include?(post.id)
        AnonymousCrawlerPostDecorator.new(post, anon_user)
      elsif post.cooked.to_s.include?("aside")
        AnonymousCrawlerPostDecorator.new(post)
      else
        post
      end
    end
  end
end

module ::AnonymousCrawlerTopicsControllerExtension
  def perform_show_response(*args, **kwargs, &block)
    if SiteSetting.anonymous_post_enabled &&
       @topic_view &&
       respond_to?(:use_crawler_layout?, true) &&
       use_crawler_layout? &&
       AnonymousPostHelper.hide_real_author?(guardian)
      @topic_view.enable_anonymous_crawler_mask! if @topic_view.respond_to?(:enable_anonymous_crawler_mask!)
    end

    super(*args, **kwargs, &block)
  end
end

module AnonymousPost
  module CrawlerExtension
    def self.apply!(_plugin)
      TopicView.prepend(AnonymousCrawlerTopicViewExtension) if defined?(TopicView)
      TopicsController.prepend(AnonymousCrawlerTopicsControllerExtension) if defined?(TopicsController)
    end
  end
end
