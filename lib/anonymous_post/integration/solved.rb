# frozen_string_literal: true

# --- discourse-solved: anonymize "Solved by" display ---
# discourse-solved prepends TopicViewSerializerExtension which defines
# accepted_answer without calling super, so we can't intercept it directly.
# Instead, we wrap as_json to post-process the serialized output.

module ::AnonymousSolvedJsonExtension
  def as_json(*)
    result = super
    return result if !SiteSetting.anonymous_post_enabled
    aa = result[:accepted_answer]
    return result unless aa.is_a?(Hash)
    return result if AnonymousPostHelper.can_reveal?(scope)

    topic = object.topic
    return result unless AnonymousPostHelper.anon_topic?(topic)

    # Anonymize solver if their answer post is anonymous
    if aa[:username].present?
      answer_post = topic.solved&.answer_post rescue nil
      if answer_post && AnonymousPostHelper.anon_post_by_id?(answer_post.id)
        anon = AnonymousPostHelper.anonymous_user_hash
        aa[:username] = anon[:username]
        aa[:name] = anon[:name]
      end
    end

    # Anonymize accepter if they are the topic owner
    if aa[:accepter_username].present?
      accepter = topic.solved&.accepter rescue nil
      if accepter&.id == topic.user_id
        anon = AnonymousPostHelper.anonymous_user_hash
        aa[:accepter_username] = anon[:username]
        aa[:accepter_name] = anon[:name]
      end
    end

    result
  end
end

# --- discourse-solved: hide anonymous solved posts from "Решённые" tab ---

module ::AnonymousSolvedTopicsExtension
  def by_user
    if SiteSetting.anonymous_post_enabled
      begin
        target_user = User.find_by(username: params[:username])

        # If viewing someone else's profile and not in reveal groups, filter anonymous posts
        if target_user && current_user&.id != target_user.id &&
           !AnonymousPostHelper.can_reveal?(guardian)
          anon_post_ids =
            PostCustomField.where(name: "is_anonymous_post", value: "1").pluck(:post_id)

          if anon_post_ids.present?
            user =
              fetch_user_from_params(
                include_inactive:
                  current_user.try(:staff?) || (current_user && SiteSetting.show_inactive_accounts),
              )
            raise Discourse::NotFound unless guardian.public_can_see_profiles?
            raise Discourse::NotFound unless guardian.can_see_profile?(user)

            offset = [0, params[:offset].to_i].max
            limit = params.fetch(:limit, 30).to_i

            solved_table = DiscourseSolved::SolvedTopic.table_name

            posts =
              Post
                .joins(
                  "INNER JOIN #{solved_table} ON #{solved_table}.answer_post_id = posts.id",
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
                .includes(:user, topic: %i[category tags])
                .order("#{solved_table}.created_at DESC")
                .offset(offset)
                .limit(limit)

            render_serialized(posts, DiscourseSolved::SolvedPostSerializer, root: "user_solved_posts")
            return
          end
        end
      rescue Discourse::NotFound
        raise
      rescue => e
        Rails.logger.error("[AnonymousPost] solved by_user filter error: #{e.class}: #{e.message}\n#{e.backtrace.first(5).join("\n")}")
        # Fall through to super on unexpected errors
      end
    end

    super
  end
end

module AnonymousPost
  module Integration
    module Solved
      def self.apply!(plugin)
        # --- discourse-solved: anonymize "accepted solution" notifications ---
        # Registered unconditionally — the event simply never fires without DiscourseSolved.

        plugin.on(:accepted_solution) do |post|
          next unless SiteSetting.anonymous_post_enabled
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

        # --- discourse-solved: anonymize MessageBus broadcast on answer accept ---
        # AcceptAnswer#publish_solution broadcasts accepted_answer_post_info to ALL
        # topic subscribers via MessageBus, bypassing all serializer patches entirely.
        # We override publish_solution to strip real usernames before broadcasting.

        if defined?(DiscourseSolved::AcceptAnswer)
          DiscourseSolved::AcceptAnswer.class_eval do
            private

            alias_method :original_publish_solution, :publish_solution

            def publish_solution(post:, topic:)
              DiscourseEvent.trigger(:accepted_solution, post)

              answer_info = topic.reload.accepted_answer_post_info

              if SiteSetting.anonymous_post_enabled && answer_info && AnonymousPostHelper.anon_topic?(topic)
                anon_name = AnonymousPostHelper.anon_username
                answer_post = topic.solved&.answer_post

                if answer_post && AnonymousPostHelper.anon_post_by_id?(answer_post.id)
                  answer_info = answer_info.merge(username: anon_name, name: nil)
                end

                if SiteSetting.show_who_marked_solved
                  accepter = topic.solved&.accepter
                  if accepter&.id == topic.user_id
                    answer_info = answer_info.merge(accepter_username: anon_name, accepter_name: nil)
                  end
                end
              end

              MessageBus.publish(
                "/topic/#{topic.id}",
                { type: :accepted_solution, accepted_answer: answer_info },
                topic.secure_audience_publish_messages,
              )
            end
          end
        end

        TopicViewSerializer.prepend(AnonymousSolvedJsonExtension)

        # --- discourse-solved: anonymize JSON-LD structured data (QAPage schema) ---
        # DiscourseSolved::QuestionSchemaSerializer#author uses object.user directly,
        # bypassing all serializer patches above. We override it to return the anonymous
        # user when the topic is marked as anonymous.

        if defined?(DiscourseSolved::QuestionSchemaSerializer)
          DiscourseSolved::QuestionSchemaSerializer.class_eval do
            def author
              return(
                { "@type" => "Person", "name" => object.user&.username, "url" => object.user&.full_url }
              ) unless SiteSetting.anonymous_post_enabled && AnonymousPostHelper.anon_topic?(object)

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
              ) unless SiteSetting.anonymous_post_enabled && AnonymousPostHelper.anon_post_by_id?(object.id)

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
              return original_solved_post_username unless SiteSetting.anonymous_post_enabled && AnonymousPostHelper.anon_post_by_id?(object.id)
              AnonymousPostHelper.anon_username
            end

            alias_method :original_solved_post_name, :name
            def name
              return original_solved_post_name unless SiteSetting.anonymous_post_enabled && AnonymousPostHelper.anon_post_by_id?(object.id)
              AnonymousPostHelper.anonymous_user_hash[:name]
            end

            alias_method :original_solved_post_avatar_template, :avatar_template
            def avatar_template
              return original_solved_post_avatar_template unless SiteSetting.anonymous_post_enabled && AnonymousPostHelper.anon_post_by_id?(object.id)
              AnonymousPostHelper.anonymous_user_hash[:avatar_template]
            end

            alias_method :original_solved_post_user_id, :user_id
            def user_id
              return original_solved_post_user_id unless SiteSetting.anonymous_post_enabled && AnonymousPostHelper.anon_post_by_id?(object.id)
              AnonymousPostHelper.anonymous_user_hash[:id]
            end
          end
        end

        if defined?(DiscourseSolved::SolvedTopicsController)
          DiscourseSolved::SolvedTopicsController.prepend(AnonymousSolvedTopicsExtension)
        end
      end
    end
  end
end
