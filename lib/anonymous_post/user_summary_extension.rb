# frozen_string_literal: true

module AnonymousPost
  module UserSummaryExtension
    def self.apply!(_plugin)
      module ::AnonymousUserSummaryExtension
        def top_replies
          results = super
          return results if !SiteSetting.anonymous_post_enabled
          return results if @guardian && AnonymousPostHelper.can_reveal?(@guardian)
          return results if @guardian&.user&.id == @user.id
          anon_ids = AnonymousPostHelper.anon_topic_ids_for_user(@user.id)
          anon_post_ids = PostCustomField.where(name: "is_anonymous_post", value: "1").pluck(:post_id).to_set
          results.reject { |r| anon_post_ids.include?(r.id) || anon_ids.include?(r.topic_id) }
        end

        def top_topics
          results = super
          return results if !SiteSetting.anonymous_post_enabled
          anon_ids = AnonymousPostHelper.anon_topic_ids_for_user(@user.id)
          return results if anon_ids.empty?
          results.reject { |t| anon_ids.include?(t.id) }
        end

        def replies
          results = super
          return results if !SiteSetting.anonymous_post_enabled
          return results if @guardian && AnonymousPostHelper.can_reveal?(@guardian)
          return results if @guardian&.user&.id == @user.id
          anon_ids = AnonymousPostHelper.anon_topic_ids_for_user(@user.id)
          anon_post_ids = PostCustomField.where(name: "is_anonymous_post", value: "1").pluck(:post_id).to_set
          results.reject { |r| anon_post_ids.include?(r.id) || anon_ids.include?(r.topic_id) }
        end

        def topics
          results = super
          return results if !SiteSetting.anonymous_post_enabled
          anon_ids = AnonymousPostHelper.anon_topic_ids_for_user(@user.id)
          return results if anon_ids.empty?
          results.reject { |t| anon_ids.include?(t.id) }
        end

        # Issue 1: hide links posted while anonymous
        def links
          results = super
          return results if !SiteSetting.anonymous_post_enabled
          return results if @guardian && AnonymousPostHelper.can_reveal?(@guardian)
          anon_ids = AnonymousPostHelper.anon_topic_ids_for_user(@user.id)
          return results if anon_ids.empty?
          results.reject { |l| anon_ids.include?(l.topic_id) }
        end

        # Issue 2: hide "most active respondents" from anonymous topics
        def most_replied_to_users
          return super if !SiteSetting.anonymous_post_enabled
          return super if @guardian && AnonymousPostHelper.can_reveal?(@guardian)
          anon_ids = AnonymousPostHelper.anon_topic_ids_for_user(@user.id)
          return super if anon_ids.empty?

          replied_users = {}
          post_query
            .where.not("topics.id" => anon_ids.to_a)
            .joins(
              "JOIN posts replies ON posts.topic_id = replies.topic_id AND posts.reply_to_post_number = replies.post_number",
            )
            .joins("JOIN topics rpt ON replies.topic_id = rpt.id AND rpt.archetype <> 'private_message'")
            .joins(
              "AND replies.post_type IN (#{Topic.visible_post_types(@user, include_moderator_actions: false).join(",")})",
            )
            .where("replies.user_id <> posts.user_id")
            .group("replies.user_id")
            .order("COUNT(*) DESC")
            .limit(UserSummary::MAX_SUMMARY_RESULTS)
            .pluck("replies.user_id, COUNT(*)")
            .each { |r| replied_users[r[0]] = r[1] }

          user_counts(replied_users)
        rescue => e
          Rails.logger.warn("[AnonymousPost] most_replied_to_users filter error: #{e.message}")
          super
        end

        # Issue 2: hide "fans / most liked by" from anonymous topics
        def most_liked_by_users
          return super if !SiteSetting.anonymous_post_enabled
          return super if @guardian && AnonymousPostHelper.can_reveal?(@guardian)
          anon_ids = AnonymousPostHelper.anon_topic_ids_for_user(@user.id)
          return super if anon_ids.empty?

          likers = {}
          UserAction
            .joins(:target_topic, :target_post)
            .merge(Topic.listable_topics.visible.secured(@guardian))
            .where(user: @user)
            .where(action_type: UserAction::WAS_LIKED)
            .where.not("topics.id" => anon_ids.to_a)
            .group(:acting_user_id)
            .order("COUNT(*) DESC")
            .limit(UserSummary::MAX_SUMMARY_RESULTS)
            .pluck("acting_user_id, COUNT(*)")
            .each { |l| likers[l[0]] = l[1] }

          user_counts(likers)
        rescue => e
          Rails.logger.warn("[AnonymousPost] most_liked_by_users filter error: #{e.message}")
          super
        end

        # Issue 3: exclude anonymous topics from "top categories" stats
        # NOTE: Discourse method is top_categories, not categories
        def top_categories
          results = super
          return results if !SiteSetting.anonymous_post_enabled
          return results if @guardian && AnonymousPostHelper.can_reveal?(@guardian)
          anon_ids = AnonymousPostHelper.anon_topic_ids_for_user(@user.id)
          return results if anon_ids.empty?

          anon_ids_array = anon_ids.to_a
          category_ids = results.map(&:id)

          # Recount topic_count excluding anonymous topics
          # CategoryWithCounts is OpenStruct — attributes are mutable
          topic_counts =
            Topic
              .listable_topics
              .visible
              .secured(@guardian)
              .where(user: @user)
              .where(category_id: category_ids)
              .where.not(id: anon_ids_array)
              .group(:category_id)
              .count

          # Recount post_count (replies only: post_number > 1) excluding anonymous topics
          post_counts =
            Post
              .joins(:topic)
              .where(
                "posts.post_type IN (?)",
                Topic.visible_post_types(@guardian&.user, include_moderator_actions: false),
              )
              .merge(Topic.listable_topics.visible.secured(@guardian))
              .where(user: @user)
              .where("posts.post_number > 1")
              .where("topics.category_id IN (?)", category_ids)
              .where.not("topics.id" => anon_ids_array)
              .group("topics.category_id")
              .count

          results
            .each do |c|
              c.topic_count = topic_counts[c.id] || 0
              c.post_count = post_counts[c.id] || 0
            end
            .reject { |c| c.topic_count + c.post_count == 0 }
            .sort_by { |c| -(c.topic_count + c.post_count) }
        rescue => e
          Rails.logger.warn("[AnonymousPost] top_categories filter error: #{e.message}")
          super
        end
      end

      UserSummary.prepend(AnonymousUserSummaryExtension)
    end
  end
end
