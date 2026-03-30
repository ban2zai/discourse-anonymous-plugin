# frozen_string_literal: true

module AnonymousPost
  module Integration
    module Reactions
      def self.apply!(_plugin)
        # --- discourse-reactions: anonymize reaction users on anonymous posts ---

        if defined?(UserReactionSerializer)
          UserReactionSerializer.class_eval do
            alias_method :original_user, :user
            def user
              return original_user if !SiteSetting.anonymous_post_enabled

              reaction_user = object.user
              post = object.post
              return reaction_user unless post

              topic = post.topic
              return reaction_user unless topic
              return reaction_user if AnonymousPostHelper.can_reveal?(scope)

              if AnonymousPostHelper.should_anonymize_reaction_user?(reaction_user, topic, post, scope.user)
                AnonymousPostHelper.anonymous_user_object
              else
                reaction_user
              end
            end
          end
        end

        # --- discourse-reactions: anonymize users in reactions-users controller endpoint ---

        # --- discourse-reactions: anonymize refresh_notification (called on reaction delete) ---
        # refresh_notification вызывает Notification.create напрямую, минуя PostAlerter,
        # поэтому патч create_notification там не срабатывает.

        if defined?(DiscourseReactions::ReactionNotification)
          DiscourseReactions::ReactionNotification.class_eval do
            private

            alias_method :original_remaining_reaction_data, :remaining_reaction_data
            def remaining_reaction_data
              data = original_remaining_reaction_data
              return data unless SiteSetting.anonymous_post_enabled

              topic = @post.topic
              return data unless topic

              # Определяем guardian для проверки прав — используем системного пользователя (нет текущего юзера)
              # Для refresh_notification нет "текущего" зрителя, поэтому анонимизируем всегда
              anon_username = AnonymousPostHelper.anon_username

              data.map do |username, name, reaction_value|
                user = User.find_by(username: username)
                next [username, name, reaction_value] unless user

                if AnonymousPostHelper.user_has_anon_posts_in_topic?(user.id, topic.id) ||
                   (AnonymousPostHelper.anon_topic?(topic) && topic.user_id == user.id)
                  anon = AnonymousPostHelper.anonymous_user
                  [
                    anon&.username || anon_username,
                    anon&.name,
                    reaction_value,
                  ]
                else
                  [username, name, reaction_value]
                end
              end
            end
          end
        end

        if defined?(DiscourseReactions::CustomReactionsController)
          DiscourseReactions::CustomReactionsController.class_eval do
            private

            alias_method :original_secure_reaction_users!, :secure_reaction_users!
            def secure_reaction_users!(reaction_users)
              result = original_secure_reaction_users!(reaction_users)

              return result unless SiteSetting.anonymous_post_enabled
              return result if AnonymousPostHelper.can_reveal?(guardian)

              # Утечка 2: убрать реакции на анонимные посты.
              # Иначе страница /u/[user]/activity/reactions раскрывает автора анонимного поста.
              anon_post_ids =
                PostCustomField.where(name: "is_anonymous_post", value: "1").select(:post_id)
              result = result.where.not(post_id: anon_post_ids)

              # Утечка 3: убрать реакции в анонимных топиках.
              # Иначе публичная страница реакций анонимного автора раскрывает что он активен в топике.
              if params[:username].present?
                profile_user = User.find_by(username: params[:username])
                if profile_user
                  anon_topic_ids = AnonymousPostHelper.anon_topic_ids_for_user(profile_user.id)
                  if anon_topic_ids.any?
                    anon_topic_post_ids = Post.where(topic_id: anon_topic_ids.to_a).select(:id)
                    result = result.where.not(post_id: anon_topic_post_ids)
                  end
                end
              end

              result
            end

            alias_method :original_get_users, :get_users
            def get_users(reaction)
              return original_get_users(reaction) if !SiteSetting.anonymous_post_enabled
              return original_get_users(reaction) if AnonymousPostHelper.can_reveal?(guardian)

              post = reaction.post
              topic = post&.topic
              return original_get_users(reaction) unless topic

              anon_data = AnonymousPostHelper.anonymous_user_hash

              reaction
                .reaction_users
                .includes(:user)
                .order("discourse_reactions_reaction_users.created_at desc")
                .limit(self.class.const_get(:MAX_USERS_COUNT) + 1)
                .map do |reaction_user|
                  user = reaction_user.user
                  if AnonymousPostHelper.should_anonymize_reaction_user?(user, topic, post, guardian.user)
                    {
                      username: anon_data[:username],
                      name: anon_data[:name],
                      avatar_template: anon_data[:avatar_template],
                      can_undo: reaction_user.can_undo?,
                      created_at: reaction_user.created_at.to_s,
                    }
                  else
                    {
                      username: user.username,
                      name: user.name,
                      avatar_template: user.avatar_template,
                      can_undo: reaction_user.can_undo?,
                      created_at: reaction_user.created_at.to_s,
                    }
                  end
                end
            end

            alias_method :original_format_like_user, :format_like_user
            def format_like_user(like)
              return original_format_like_user(like) if !SiteSetting.anonymous_post_enabled
              return original_format_like_user(like) if AnonymousPostHelper.can_reveal?(guardian)

              post = like.post
              topic = post&.topic
              return original_format_like_user(like) unless topic

              user = like.user
              if AnonymousPostHelper.should_anonymize_reaction_user?(user, topic, post, guardian.user)
                anon_data = AnonymousPostHelper.anonymous_user_hash
                {
                  username: anon_data[:username],
                  name: anon_data[:name],
                  avatar_template: anon_data[:avatar_template],
                  can_undo: guardian.can_delete_post_action?(like),
                  created_at: like.created_at.to_s,
                }
              else
                original_format_like_user(like)
              end
            end
          end
        end
      end
    end
  end
end
