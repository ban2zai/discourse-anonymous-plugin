# frozen_string_literal: true

module AnonymousPost
  module UserActionFilter
    def self.apply!(_plugin)
      UserAction.class_eval do
        class << self
          alias_method :original_stream, :stream

          def stream(opts = {})
            result = original_stream(opts)

            guardian = opts[:guardian]
            acting_user_id = opts[:user_id]

            can_reveal = guardian && AnonymousPostHelper.can_reveal?(guardian)
            is_owner   = acting_user_id && guardian&.user&.id == acting_user_id
            if SiteSetting.anonymous_post_enabled && !can_reveal
              actions_array = result.to_a

              # Helper: UserAction AR model uses target_post_id / target_topic_id,
              # but some Discourse versions return DB::Result structs aliased as post_id / topic_id.
              # Support both to be safe.
              read_post_id  = ->(a) { (a.try(:post_id)  || a.try(:target_post_id)).to_i.then  { |v| v.positive? ? v : nil } }
              read_topic_id = ->(a) { (a.try(:topic_id) || a.try(:target_topic_id)).to_i.then { |v| v.positive? ? v : nil } }

              # Batch-collect IDs for efficient DB lookups
              topic_ids = actions_array.filter_map { |a| read_topic_id.call(a) }.uniq
              post_ids  = actions_array.filter_map { |a| read_post_id.call(a)  }.uniq

              # 1. Explicitly anonymous posts
              explicit_anon_post_ids =
                post_ids.any? ?
                  PostCustomField.where(post_id: post_ids, name: "is_anonymous_post", value: "1").pluck(:post_id).to_set :
                  Set.new

              # 2. Anonymous topics and their owners
              anon_topic_ids =
                topic_ids.any? ?
                  TopicCustomField.where(topic_id: topic_ids, name: "is_anonymous_topic", value: "1").pluck(:topic_id).to_set :
                  Set.new

              anon_topic_owners =
                anon_topic_ids.any? ?
                  Topic.where(id: anon_topic_ids.to_a).pluck(:id, :user_id).to_h :
                  {}

              # 3. Authors of posts in anonymous topics (to detect when a third party liked
              #    an anonymous author's post, which would expose the author's identity)
              post_authors_in_anon_topics =
                (post_ids.any? && anon_topic_ids.any?) ?
                  Post.where(id: post_ids, topic_id: anon_topic_ids.to_a).pluck(:id, :user_id).to_h :
                  {}

              result = actions_array.reject do |action|
                post_id     = read_post_id.call(action)
                topic_id    = read_topic_id.call(action)
                action_type = action.try(:action_type).to_i

                # Post is explicitly marked as anonymous.
                # For the profile owner: only filter LIKE actions (they liked someone else's
                # anonymous post). Non-LIKE actions are their own anonymous posts — keep visible.
                if post_id && explicit_anon_post_ids.include?(post_id)
                  next true if !is_owner || action_type == UserAction::LIKE
                end

                if topic_id && anon_topic_ids.include?(topic_id)
                  owner_id = anon_topic_owners[topic_id]

                  # Post is by the anonymous topic owner — reveals their identity
                  # (e.g. third party liked an anonymous post → shows real author in likes-given).
                  # Same owner-exemption logic: allow the owner to see their own post activity,
                  # but still filter if they liked the post (they aren't the author in that case).
                  if post_id && owner_id
                    post_author_id = post_authors_in_anon_topics[post_id]
                    if post_author_id == owner_id
                      next true if !is_owner || action_type == UserAction::LIKE
                    end
                  end

                  # Action is in an anonymous topic owned by the profile user — reveals they own it.
                  # Only apply to non-owners; the owner is allowed to see their own topic activity.
                  next true if owner_id == acting_user_id && !is_owner
                end

                false
              end
            end

            result
          end
        end
      end
    end
  end
end
