# frozen_string_literal: true

module AnonymousPost
  module SearchFilter
    def self.apply!(plugin)
      # --- TopicQuery: hide anonymous topics from "Темы" tab on user profile ---
      # Uses register_modifier to filter at SQL level, before topics.to_a is called
      # in create_list. This is more reliable than post-filtering the loaded Array.
      plugin.register_modifier(:topic_query_create_list_topics) do |topics, options, topic_query|
        next topics unless SiteSetting.anonymous_post_enabled
        next topics unless options[:filter] == :user_topics

        guardian = topic_query.instance_variable_get(:@guardian)
        next topics if guardian.nil?

        profile_user_id = topic_query.instance_variable_get(:@options)[:filtered_to_user]
        next topics unless profile_user_id

        next topics if guardian.user&.id == profile_user_id
        next topics if AnonymousPostHelper.can_reveal?(guardian)

        topics.where.not(
          id: TopicCustomField.where(name: "is_anonymous_topic", value: "1").select(:topic_id),
        )
      end

      # --- Search: exclude anonymous posts from @username searches ---

      Search.class_eval do
        alias_method :original_execute, :execute
        def execute(readonly_mode: Discourse.readonly_mode?)
          results = original_execute(readonly_mode: readonly_mode)
          return results if !SiteSetting.anonymous_post_enabled

          begin
            # Detect user-scoped search: either via search_context or @username in search term
            # @clean_term is the raw unprocessed search input (set in initialize before prepare_data)
            # The @username advanced_filter adds posts.where("posts.user_id = ?") directly
            # without setting @search_context, so we must check both cases
            has_user_filter = @search_context.is_a?(User) || @clean_term.to_s.match?(/@\S+/)

            if has_user_filter && results&.posts.present?
              guardian = @guardian || Guardian.new

              # Determine the user being searched to scope topic-level hiding.
              # Only hide anonymous topics where THIS specific user was the anonymous author.
              # Other users' posts in that topic remain visible (they were NOT anonymous).
              searched_user =
                if @search_context.is_a?(User)
                  @search_context
                else
                  username = @clean_term.to_s.match(/@(\S+)/)&.[](1)
                  username ? User.find_by(username: username) : nil
                end

              # Authors always see their own anonymous posts; reveal_groups members see all
              is_own_search = searched_user && guardian.user&.id == searched_user.id

              unless AnonymousPostHelper.can_reveal?(guardian) || is_own_search
                post_ids = results.posts.map(&:id)

                # Posts explicitly marked as anonymous — always hide
                anon_post_ids = PostCustomField.where(
                  name: "is_anonymous_post",
                  value: "1",
                  post_id: post_ids
                ).pluck(:post_id).to_set

                anon_topic_ids_for_searched =
                  if searched_user
                    AnonymousPostHelper.anon_topic_ids_for_user(searched_user.id)
                  else
                    Set.new
                  end

                results.posts.reject! do |p|
                  anon_post_ids.include?(p.id) || anon_topic_ids_for_searched.include?(p.topic_id)
                end
              end
            end
          rescue => e
            Rails.logger.error("AnonymousPost search filter error: #{e.class}: #{e.message}\n#{e.backtrace.first(5).join("\n")}")
          end

          results
        end
      end
    end
  end
end
