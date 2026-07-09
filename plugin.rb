# frozen_string_literal: true

# name: discourse-anonymous-plugin
# version: 0.4.0
# authors: github.com/ban2zai
# url: https://github.com/ban2zai/discourse-anonymous-plugin

%i[common mobile].each do |layout|
  register_asset "stylesheets/anonymous-post/#{layout}.scss", layout
end

enabled_site_setting :anonymous_post_enabled

after_initialize do
  register_svg_icon "ghost"
  add_permitted_post_create_param(:is_anonymous_post)
  register_post_custom_field_type("is_anonymous_post", :integer)
  register_topic_custom_field_type("is_anonymous_topic", :integer)

  # Preload custom fields to avoid N+1 queries (HasCustomFields::NotPreloadedError)
  if TopicList.respond_to?(:preloaded_custom_fields)
    TopicList.preloaded_custom_fields << "is_anonymous_topic" unless TopicList.preloaded_custom_fields.include?("is_anonymous_topic")
  end

  if TopicList.respond_to?(:on_preload)
    TopicList.on_preload do |*args|
      topic_list = args.find { |arg| arg.respond_to?(:topics) }
      topics = topic_list&.topics || args.find { |arg| arg.is_a?(Array) } || []
      Topic.preload_custom_fields(topics, ["is_anonymous_topic"]) if topics.present? && Topic.respond_to?(:preload_custom_fields)
    end
  end

  if TopicView.respond_to?(:default_post_custom_fields)
    TopicView.default_post_custom_fields << "is_anonymous_post" unless TopicView.default_post_custom_fields.include?("is_anonymous_post")
  elsif TopicView.respond_to?(:add_post_custom_fields_allowlister)
    TopicView.add_post_custom_fields_allowlister { |_user| ["is_anonymous_post"] }
  elsif TopicView.respond_to?(:on_preload)
    TopicView.on_preload do |topic_view|
      Post.preload_custom_fields(topic_view.posts, ["is_anonymous_post"]) if topic_view.respond_to?(:posts)
    end
  end

  %w[
    helper
    post_creation_handler
    post_serializers
    raw_endpoints
    crawler_extension
    webhook_serializers
    topic_view_extensions
    topic_serializers
    user_summary_extension
    user_action_filter
    search_filter
    notifications
    misc_serializers
    onebox_extension
    username_suggester
    integration/reactions
    integration/solved
  ].each { |f| require_relative "lib/anonymous_post/#{f}" }

  on(:post_created) { |post, opts| AnonymousPost::PostCreationHandler.handle(post, opts) }

  [
    AnonymousPost::PostSerializers,
    AnonymousPost::RawEndpoints,
    AnonymousPost::CrawlerExtension,
    AnonymousPost::WebhookSerializers,
    AnonymousPost::TopicViewExtensions,
    AnonymousPost::TopicSerializers,
    AnonymousPost::UserSummaryExtension,
    AnonymousPost::UserActionFilter,
    AnonymousPost::SearchFilter,
    AnonymousPost::Notifications,
    AnonymousPost::MiscSerializers,
    AnonymousPost::OneboxExtension,
    AnonymousPost::UsernameSuggester,
    AnonymousPost::Integration::Reactions,
    AnonymousPost::Integration::Solved,
  ].each { |mod| mod.apply!(self) }
end
