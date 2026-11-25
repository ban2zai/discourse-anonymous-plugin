# frozen_string_literal: true

module ::AnonymousSolvedAnswersExtension
  def serialize(topic, guardian, broadcast: false)
    answers = super(topic, guardian)
    return unless answers

    return answers unless broadcast || AnonymousPostHelper.hide_real_author?(guardian)

    topic_answers = topic.topic_answers.index_by(&:answer_post_id)
    if broadcast
      # Получатели рассылки могут видеть тему, но не все ее посты.
      visible_types = Topic.visible_post_types
      answers.select! do |answer|
        post = topic_answers.fetch(answer[:id]).post
        !post.hidden? && !post.trashed? && visible_types.include?(post.post_type)
      end
      return if answers.empty?
    end
    posts = answers.map { |answer| topic_answers.fetch(answer[:id]).post }
    anonymous_ids = AnonymousPostHelper.anonymous_author_post_ids(posts, topic)
    anonymous_topic = AnonymousPostHelper.anon_topic?(topic)
    anon = AnonymousPostHelper.anonymous_user_hash

    answers.each do |answer|
      topic_answer = topic_answers.fetch(answer[:id])
      if anonymous_ids.include?(topic_answer.answer_post_id)
        %i[username name avatar_template].each { |key| answer[key] = anon[key] if answer.key?(key) }
      end

      accepter_id = topic_answer.accepter&.id || topic.user_id
      if anonymous_topic && accepter_id == topic.user_id
        answer[:accepter_username] = anon[:username] if answer.key?(:accepter_username)
        answer[:accepter_name] = anon[:name] if answer.key?(:accepter_name)
      end

      if broadcast && answer.key?(:cooked)
        answer[:cooked] = AnonymousPostHelper.anonymize_cooked_quotes(answer[:cooked])
      end
    end
  end
end

module ::AnonymousSolvedTopicsExtension
  def by_user
    return super unless AnonymousPostHelper.hide_real_author?(guardian)

    params.require(:username)
    user =
      fetch_user_from_params(
        include_inactive:
          current_user.try(:staff?) || (current_user && SiteSetting.show_inactive_accounts),
      )
    return super if current_user&.id == user.id

    raise Discourse::NotFound unless guardian.public_can_see_profiles?
    raise Discourse::NotFound unless guardian.can_see_profile?(user)
    raise Discourse::NotFound unless guardian.can_see_user_actions?(user)

    anon_post_ids = PostCustomField.where(name: "is_anonymous_post", value: "1").select(:post_id)
    anon_topic_ids = TopicCustomField.where(name: "is_anonymous_topic", value: "1").select(:topic_id)
    anon_owned_topics = Topic.where(user_id: user.id, id: anon_topic_ids).select(:id)

    posts =
      Post
        .joins(
          "INNER JOIN discourse_solved_topic_answers ON discourse_solved_topic_answers.answer_post_id = posts.id",
          "INNER JOIN discourse_solved_solved_topics ON discourse_solved_solved_topics.id = discourse_solved_topic_answers.solved_topic_id",
        )
        .joins(:topic)
        .joins("LEFT JOIN categories ON categories.id = topics.category_id")
        .where(user_id: user.id, deleted_at: nil)
        .where(topics: { archetype: Archetype.default, deleted_at: nil })
        .where(
          "topics.category_id IS NULL OR NOT categories.read_restricted OR topics.category_id IN (:secure_category_ids)",
          secure_category_ids: guardian.secure_category_ids,
        )
        .where.not(id: anon_post_ids)
        .where.not(topic_id: anon_owned_topics)

    posts = posts.where(topics: { visible: true }) unless guardian.can_see_unlisted_topics?
    posts = guardian.filter_hidden_posts(posts)
    posts =
      posts.where(
        "posts.user_id = :current_user_id OR posts.post_type IN (:visible_post_types)",
        current_user_id: current_user&.id || Discourse.system_user.id,
        visible_post_types: Topic.visible_post_types(current_user),
      )

    posts =
      posts
        .includes(:user, topic: %i[category tags])
        .order("discourse_solved_topic_answers.created_at DESC")
        .offset([0, params[:offset].to_i].max)
        .limit(params.fetch(:limit, 30).to_i)
        .select { |post| guardian.can_see_post?(post) }

    render_serialized(posts, DiscourseSolved::SolvedPostSerializer, root: "user_solved_posts")
  end
end

module AnonymousPost
  module Integration
    module Solved
      def self.publish(type, post:, topic:, guardian:)
        DiscourseEvent.trigger(type, post, acting_user: guardian.user)
        MessageBus.publish(
          "/topic/#{topic.id}",
          {
            type: type,
            accepted_answers:
              DiscourseSolved::AcceptedAnswersHelper.serialize(
                topic.reload,
                guardian,
                broadcast: true,
              ),
          },
          topic.secure_audience_publish_messages,
        )
      end

      def self.apply!(plugin)
        # --- discourse-solved: anonymize "accepted solution" notifications ---
        # Registered unconditionally — the event simply never fires without DiscourseSolved.

        plugin.on(:accepted_solution) do |post|
          topic = post&.topic
          if topic && AnonymousPostHelper.anon_topic?(topic)
            anon = AnonymousPostHelper.anonymous_user
            Notification.where(
              topic_id: topic.id,
              post_number: post.post_number,
            ).where("created_at > ?", 1.minute.ago).each do |n|
              data = JSON.parse(n.data)
              if data["display_username"].present?
                data["display_username"] = anon&.username || AnonymousPostHelper.anon_username
                data["username"] = anon&.username || AnonymousPostHelper.anon_username
                n.update(data: data.to_json)
              end
            end
          end
        end

        if defined?(DiscourseSolved::AcceptedAnswersHelper)
          DiscourseSolved::AcceptedAnswersHelper.singleton_class.prepend(AnonymousSolvedAnswersExtension)
          DiscourseSolved::SolvedTopicsController.prepend(AnonymousSolvedTopicsExtension)

          DiscourseSolved::AcceptAnswer.prepend(Module.new do
            private

            def publish_solution(post:, topic:, guardian:)
              AnonymousPost::Integration::Solved.publish(:accepted_solution, post:, topic:, guardian:)
            end
          end)

          DiscourseSolved::UnacceptAnswer.prepend(Module.new do
            private

            def publish_unaccepted(post:, topic:, guardian:)
              AnonymousPost::Integration::Solved.publish(:unaccepted_solution, post:, topic:, guardian:)
            end
          end)

          DiscourseSolved::SchemaUtils.singleton_class.prepend(Module.new do
            def post_text(post)
              super(AnonymousCrawlerPostDecorator.new(post))
            end
          end)
        end

        # --- discourse-solved: anonymize JSON-LD structured data (QAPage schema) ---
        # DiscourseSolved::QuestionSchemaSerializer#author uses object.user directly,
        # bypassing all serializer patches above. We override it to return the anonymous
        # user when the topic is marked as anonymous.

        if defined?(DiscourseSolved::QuestionSchemaSerializer)
          DiscourseSolved::QuestionSchemaSerializer.class_eval do
            def author
              return(
                { "@type" => "Person", "name" => object.user&.username, "url" => object.user&.full_url }
              ) unless AnonymousPostHelper.anon_topic?(object)

              anon_name = AnonymousPostHelper.anon_username
              { "@type" => "Person", "name" => anon_name, "url" => "#{Discourse.base_url}/u/#{anon_name}" }
            end
          end
        end

        # DiscourseSolved::AnswerSchemaSerializer#author — the accepted answer post
        # may itself be an anonymous post, leaking the real solver's username.

        if defined?(DiscourseSolved::AnswerSchemaSerializer)
          DiscourseSolved::AnswerSchemaSerializer.class_eval do
            def author
              return(
                { "@type" => "Person", "name" => object.user&.username, "url" => object.user&.full_url }
              ) unless AnonymousPostHelper.anonymous_author_post?(object)

              anon_name = AnonymousPostHelper.anon_username
              { "@type" => "Person", "name" => anon_name, "url" => "#{Discourse.base_url}/u/#{anon_name}" }
            end
          end
        end

        # DiscourseSolved::SolvedPostSerializer — defensive patch in case it is ever
        # called with an anonymous post outside the already-filtered controller.
        # NOTE: SolvedPostSerializer defines these methods directly (not inherited),
        # so we must use alias_method instead of super.

        if defined?(DiscourseSolved::SolvedPostSerializer)
          DiscourseSolved::SolvedPostSerializer.class_eval do
            alias_method :original_solved_post_username, :username
            def username
              return original_solved_post_username unless AnonymousPostHelper.anon_post_by_id?(object.id)
              AnonymousPostHelper.anon_username
            end

            alias_method :original_solved_post_name, :name
            def name
              return original_solved_post_name unless AnonymousPostHelper.anon_post_by_id?(object.id)
              AnonymousPostHelper.anonymous_user_hash[:name]
            end

            alias_method :original_solved_post_avatar_template, :avatar_template
            def avatar_template
              return original_solved_post_avatar_template unless AnonymousPostHelper.anon_post_by_id?(object.id)
              AnonymousPostHelper.anonymous_user_hash[:avatar_template]
            end

            alias_method :original_solved_post_user_id, :user_id
            def user_id
              return original_solved_post_user_id unless AnonymousPostHelper.anon_post_by_id?(object.id)
              AnonymousPostHelper.anonymous_user_hash[:id]
            end
          end
        end
      end
    end
  end
end
