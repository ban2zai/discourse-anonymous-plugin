# frozen_string_literal: true

module AnonymousPost
  module PostCreationHandler
    def self.requested?(opts)
      opts[:is_anonymous_post].to_s.to_i.positive?
    end

    def self.topic_error(topic, opts)
      return unless requested?(opts)
      return :anonymous_post_new_topics_disabled unless SiteSetting.anonymous_post_enabled

      category_id = topic.category_id
      category_id ||= SiteSetting.uncategorized_category_id if topic.regular?
      :anonymous_post_category_not_allowed unless AnonymousPostHelper.category_allowed?(category_id)
    end

    def self.apply!(plugin)
      NewPostManager.add_plugin_payload_attribute(:is_anonymous_post)

      plugin.on(:after_validate_topic) do |topic, creator|
        error = topic_error(topic, creator.opts)
        topic.errors.add(:base, I18n.t(error)) if error
      end

      plugin.on(:before_create_topic) do |topic, creator|
        next unless requested?(creator.opts)

        error = topic_error(topic, creator.opts)
        creator.rollback_with!(topic, I18n.t(error)) if error
        topic.custom_fields["is_anonymous_topic"] = 1
      end

      PostCreator.prepend(PostCreatorExtension)
    end

    module PostCreatorExtension
      def valid?
        return false unless super
        return true if new_topic? || !PostCreationHandler.requested?(opts) || anonymous_topic_owner?

        add_error(I18n.t(:anonymous_post_reply_not_allowed))
        false
      end

      private

      def transaction(&block)
        return super unless new_topic? && PostCreationHandler.requested?(opts)

        # При одобрении поста транзакция создания может быть вложенной.
        super { Post.transaction(requires_new: true, &block) }
      end

      def save_post
        unless anonymous_topic_owner?
          if PostCreationHandler.requested?(opts)
            error = new_topic? ? :anonymous_post_save_failed : :anonymous_post_reply_not_allowed
            rollback_with!(@post, I18n.t(error))
          end
          return super
        end

        @post.custom_fields["is_anonymous_post"] = 1
        result = super
        unless AnonymousPostHelper.anon_post_by_id?(@post.id)
          rollback_with!(@post, I18n.t(:anonymous_post_save_failed))
        end
        result
      end

      def anonymous_topic_owner?
        @topic && @topic.user_id == @post.user_id && AnonymousPostHelper.anon_topic?(@topic)
      end
    end
  end
end
