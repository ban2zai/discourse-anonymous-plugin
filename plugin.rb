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
  TopicList.preloaded_custom_fields << "is_anonymous_topic"

  %w[
    helper
    post_creation_handler
    post_serializers
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
