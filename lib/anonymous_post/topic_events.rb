# frozen_string_literal: true

module AnonymousPost
  module TopicEvents
    def self.apply!(_plugin)
      Post.prepend(PostEvents)
      MessageBus.singleton_class.prepend(TopicStats)
    end

    module PostEvents
      def publish_change_to_clients!(type, opts = {})
        return super unless AnonymousPostHelper.mask_author?(nil, self, force: true)

        anon = AnonymousPostHelper.anonymous_user_hash
        masked_opts = opts.merge(user_id: anon[:id])
        masked_opts[:username] = anon[:username] if type == :created || opts.key?(:username)
        if opts.fetch(:last_editor_id, last_editor_id) == user_id
          masked_opts[:last_editor_id] = anon[:id]
        end
        super(type, masked_opts)
      end
    end

    module TopicStats
      # Статистика отправляется напрямую, минуя сериализаторы темы.
      def publish(channel, data, opts = nil)
        if data.is_a?(Hash) && data[:type] == :stats && channel == "/topic/#{data[:id]}" &&
           data[:last_poster].is_a?(Hash)
          last_poster = data[:last_poster].symbolize_keys
          user_id = last_poster[:id]
          topic = Topic.find_by(id: data[:id])
          if topic && user_id && anonymous_last_poster?(topic, user_id, data[:last_posted_at])
            masked_poster = AnonymousPostHelper.anonymous_user_hash.slice(*last_poster.keys)
            return super(channel, data.merge(last_poster: masked_poster), opts)
          end
        end
        super
      end

      private

      def anonymous_last_poster?(topic, user_id, last_posted_at)
        return true if topic.user_id == user_id && AnonymousPostHelper.anon_topic?(topic)

        if topic.last_posted_at.as_json == last_posted_at
          last_post_id =
            topic.posts.where(user_id: user_id, created_at: topic.last_posted_at)
              .order(post_number: :desc)
              .pick(:id)
          return AnonymousPostHelper.anon_post_by_id?(last_post_id) if last_post_id
        end

        AnonymousPostHelper.user_has_anon_posts_in_topic?(user_id, topic.id)
      end
    end
  end
end
