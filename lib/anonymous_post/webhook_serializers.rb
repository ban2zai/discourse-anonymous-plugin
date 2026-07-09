# frozen_string_literal: true

module ::AnonymousWebHookTopicViewSerializerHelpers
  private

  def anonymous_webhook_topic
    object.respond_to?(:topic) ? object.topic : object
  end

  def anonymous_webhook_topic?
    topic = anonymous_webhook_topic
    SiteSetting.anonymous_post_enabled && topic && AnonymousPostHelper.anon_topic?(topic)
  end
end

module AnonymousPost
  module WebhookSerializers
    def self.apply!(_plugin)
      return unless defined?(WebHookTopicViewSerializer)

      WebHookTopicViewSerializer.class_eval do
        include AnonymousWebHookTopicViewSerializerHelpers

        if method_defined?(:created_by)
          alias_method :original_anonymous_webhook_created_by, :created_by
          def created_by
            anonymous_webhook_topic? ? AnonymousPostHelper.anonymous_user_object : original_anonymous_webhook_created_by
          end
        end

        if method_defined?(:last_poster)
          alias_method :original_anonymous_webhook_last_poster, :last_poster
          def last_poster
            topic = anonymous_webhook_topic
            return original_anonymous_webhook_last_poster unless SiteSetting.anonymous_post_enabled && topic

            last_post = topic.posts.order(post_number: :desc).first
            if AnonymousPostHelper.anonymous_author_post?(last_post, topic)
              AnonymousPostHelper.anonymous_user_object
            else
              original_anonymous_webhook_last_poster
            end
          end
        end

        if method_defined?(:user_id)
          alias_method :original_anonymous_webhook_user_id, :user_id
          def user_id
            anonymous_webhook_topic? ? AnonymousPostHelper.anonymous_user_hash[:id] : original_anonymous_webhook_user_id
          end
        end
      end
    end
  end
end
