# frozen_string_literal: true

module AnonymousPost
  module TopicSerializers
    def self.apply!(plugin)
      # --- TopicList#topics: anonymize dc:creator in list RSS feeds (latest.rss, etc.) ---
      # list.rss.erb calls rss_creator(topic.user) for each topic in @topic_list.topics.
      # We wrap anonymous topics in a decorator that overrides #user with the anon user.

      class ::AnonymousRssTopicDecorator < SimpleDelegator
        def initialize(topic, anon_user)
          super(topic)
          @anon_user = anon_user
        end

        def user
          @anon_user
        end

        # Ensure type checks against Topic still pass (e.g. topic.is_a?(Topic))
        def is_a?(klass)
          super || __getobj__.is_a?(klass)
        end
        alias kind_of? is_a?

        def class
          __getobj__.class
        end
      end

      module ::AnonymousTopicListRssExtension
        def topics
          result = super
          return result unless SiteSetting.anonymous_post_enabled

          topics_array = Array(result)
          return result if topics_array.empty?

          topic_ids = topics_array.map(&:id)
          anon_topic_ids =
            TopicCustomField
              .where(topic_id: topic_ids, name: "is_anonymous_topic", value: "1")
              .pluck(:topic_id)
              .to_set

          return result if anon_topic_ids.empty?

          anon_user =
            AnonymousPostHelper.anonymous_user ||
              OpenStruct.new(display_name: AnonymousPostHelper.anon_username)

          topics_array.map do |topic|
            anon_topic_ids.include?(topic.id) ? AnonymousRssTopicDecorator.new(topic, anon_user) : topic
          end
        end
      end

      TopicList.prepend(AnonymousTopicListRssExtension)

      # --- TopicViewSerializer: topic-level fields ---

      plugin.add_to_serializer(:topic_view, :is_anonymous_topic) do
        object.topic.custom_fields["is_anonymous_topic"].to_i
      end

      plugin.add_to_serializer(:topic_view, :user_id) do
        topic = object.topic
        if SiteSetting.anonymous_post_enabled &&
           AnonymousPostHelper.anon_topic?(topic) && !AnonymousPostHelper.can_reveal?(scope) && scope.user&.id != topic.user_id
          nil
        else
          topic.user_id
        end
      end

      # --- TopicViewDetailsSerializer: created_by, last_poster, participants ---

      TopicViewDetailsSerializer.class_eval do
        alias_method :original_created_by, :created_by
        def created_by
          return original_created_by if !SiteSetting.anonymous_post_enabled
          topic = object.topic
          if AnonymousPostHelper.anon_topic?(topic) && !AnonymousPostHelper.can_reveal?(scope)
            AnonymousPostHelper.anonymous_user_object
          else
            original_created_by
          end
        end

        alias_method :original_last_poster, :last_poster
        def last_poster
          return original_last_poster if !SiteSetting.anonymous_post_enabled
          topic = object.topic
          if !AnonymousPostHelper.can_reveal?(scope)
            should_anonymize = false

            if AnonymousPostHelper.anon_topic?(topic)
              last_poster_user = topic.last_poster
              should_anonymize = true if last_poster_user&.id == topic.user_id
            end

            last_post_id = topic.posts.order(post_number: :desc).limit(1).pluck(:id).first
            should_anonymize = true if last_post_id && AnonymousPostHelper.anon_post_by_id?(last_post_id)

            if should_anonymize
              return AnonymousPostHelper.anonymous_user_object
            end
          end

          original_last_poster
        end

        alias_method :original_participants, :participants
        def participants
          return original_participants if !SiteSetting.anonymous_post_enabled
          topic = object.topic
          return original_participants if AnonymousPostHelper.can_reveal?(scope)
          return original_participants unless AnonymousPostHelper.anon_topic?(topic)

          # Since only topic creator can be anonymous, just anonymize their entry
          topic_owner_id = topic.user_id

          original_participants.map do |participant|
            user = participant.is_a?(Hash) ? participant[:user] : participant
            user_id = user.respond_to?(:id) ? user.id : nil

            if user_id == topic_owner_id
              if participant.is_a?(Hash)
                { user: AnonymousPostHelper.anonymous_user_object, post_count: participant[:post_count] }
              else
                obj = AnonymousPostHelper.anonymous_user_object
                obj.post_count = user.respond_to?(:post_count) ? user.post_count : 1
                obj
              end
            else
              participant
            end
          end
        end
      end

      # --- TopicListItemSerializer: is_anonymous_topic flag for topic list ---

      plugin.add_to_serializer(:topic_list_item, :is_anonymous_topic) do
        object.custom_fields["is_anonymous_topic"].to_i
      end

      # --- TopicListItemSerializer: posters in topic list ---

      TopicListItemSerializer.class_eval do
        alias_method :original_posters, :posters
        def posters
          result = original_posters
          return result if !SiteSetting.anonymous_post_enabled
          return result if AnonymousPostHelper.can_reveal?(scope)

          topic = object
          return result unless AnonymousPostHelper.anon_topic?(topic)

          topic_owner_id = topic.user_id
          anon = AnonymousPostHelper.anonymous_user

          result.map do |poster|
            if poster.user && poster.user.id == topic_owner_id && scope.user&.id != poster.user.id && anon
              new_poster = poster.dup
              new_poster.user = anon
              new_poster
            else
              poster
            end
          end
        end
      end
    end
  end
end
