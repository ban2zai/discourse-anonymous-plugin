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

        if defined?(DiscourseReactions::CustomReactionsController)
          DiscourseReactions::CustomReactionsController.class_eval do
            private

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
