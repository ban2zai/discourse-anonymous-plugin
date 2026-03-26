# frozen_string_literal: true

# name: discourse-anonymous-plugin
# version: 0.4.0
# authors: github.com/ban2zai
# url: https://github.com/ban2zai/discourse-anonymous-plugin

%i[common mobile].each do |layout|
  register_asset "stylesheets/anonymous-post/#{layout}.scss", layout
end

enabled_site_setting :anonymous_post_enabled

after_initialize do
  register_svg_icon "ghost"
  add_permitted_post_create_param(:is_anonymous_post)
  register_post_custom_field_type("is_anonymous_post", :integer)
  register_topic_custom_field_type("is_anonymous_topic", :integer)

  # Preload custom fields to avoid N+1 queries (HasCustomFields::NotPreloadedError)
  TopicList.preloaded_custom_fields << "is_anonymous_topic"

  # --- Shared helper module ---

  module ::AnonymousPostHelper
    ANON_AVATAR_FALLBACK = "/letter_avatar_proxy/v4/letter/a/b3b5b3/{size}.png"

    def self.anon_username
      SiteSetting.anonymous_post_user.presence || "anonymous"
    end

    def self.anonymous_user
      @anon_cached_username ||= nil
      current = anon_username
      if @anon_cached_username != current
        @anonymous_user = User.find_by(username: current)
        @anon_cached_username = current
      end
      @anonymous_user
    end

    def self.reset_cache!
      @anonymous_user = nil
      @anon_cached_username = nil
    end

    def self.anonymous_user_hash
      user = anonymous_user
      if user
        {
          id: user.id,
          username: user.username,
          name: user.name || I18n.t("js.anonymous_post.anonymous_name"),
          avatar_template: user.avatar_template,
        }
      else
        {
          id: -1,
          username: anon_username,
          name: I18n.t("js.anonymous_post.anonymous_name"),
          avatar_template: ANON_AVATAR_FALLBACK,
        }
      end
    end

    # Returns a serializer-compatible object (BasicUserSerializer needs read_attribute_for_serialization)
    def self.anonymous_user_object
      data = anonymous_user_hash
      obj = OpenStruct.new(
        id: data[:id],
        username: data[:username],
        name: data[:name],
        avatar_template: data[:avatar_template],
        primary_group_id: nil,
        flair_group_id: nil,
      )
      def obj.read_attribute_for_serialization(attr)
        send(attr)
      end
      obj
    end

    def self.anon_post?(post_obj)
      post_obj.custom_fields["is_anonymous_post"].to_i == 1
    end

    # Safe check via direct DB query — avoids NotPreloadedError
    def self.anon_post_by_id?(post_id)
      PostCustomField.exists?(post_id: post_id, name: "is_anonymous_post", value: "1")
    end

    def self.anon_topic?(topic_obj)
      topic_obj.custom_fields["is_anonymous_topic"].to_i == 1
    end

    # Check if the current user can see real authors of anonymous posts
    def self.can_reveal?(scope)
      return true if scope.is_admin?
      return false unless scope.user
      allowed = SiteSetting.anonymous_post_reveal_groups
      return false if allowed.blank?
      group_ids = allowed.split("|").map(&:to_i)
      scope.user.groups.where(id: group_ids).exists?
    end

    # Check if a user has any anonymous posts in a given topic
    def self.user_has_anon_posts_in_topic?(user_id, topic_id)
      PostCustomField
        .joins(:post)
        .where(name: "is_anonymous_post", value: "1")
        .where(posts: { topic_id: topic_id, user_id: user_id })
        .exists?
    end

    # Returns the set of topic_ids where the given user is the anonymous topic creator
    def self.anon_topic_ids_for_user(user_id)
      TopicCustomField
        .where(name: "is_anonymous_topic", value: "1")
        .joins("INNER JOIN topics ON topics.id = topic_custom_fields.topic_id")
        .where(topics: { user_id: user_id })
        .pluck(:topic_id)
        .to_set
    end

    # Shared logic: should a reaction/like user be anonymized?
    def self.should_anonymize_reaction_user?(user, topic, post, current_user)
      return false if current_user&.id == user&.id

      # Anonymous topic — hide topic owner's reactions
      return true if anon_topic?(topic) && user&.id == topic.user_id

      # Anonymous post — hide post author's reactions on their own post
      return true if anon_post_by_id?(post.id) && user&.id == post.user_id

      # User has anonymous post(s) in this topic — hide all their reactions in the topic
      return true if user&.id && user_has_anon_posts_in_topic?(user.id, topic.id)

      false
    end

    # Check if category allows anonymous posting
    def self.category_allowed?(category_id)
      cat_ids = SiteSetting.anonymous_post_allowed_categories.to_s.split("|").map(&:to_i)
      cat_ids.present? && cat_ids.include?(category_id)
    end
  end

  # --- Post creation: save custom fields ---

  on(:post_created) do |post, opts|
    next unless SiteSetting.anonymous_post_enabled
    value = opts[:is_anonymous_post].to_i
    if value.positive?
      topic = post.topic
      allowed = false

      if post.post_number == 1
        # New topic — check category whitelist (empty = disabled)
        allowed = AnonymousPostHelper.category_allowed?(topic.category_id)
      else
        # Reply — only topic owner in their own anonymous topic
        allowed = AnonymousPostHelper.anon_topic?(topic) && post.user_id == topic.user_id
      end

      if allowed
        post.custom_fields["is_anonymous_post"] = value
        post.save_custom_fields(true)

        if post.post_number == 1
          topic.custom_fields["is_anonymous_topic"] = 1
          topic.save_custom_fields(true)
        end
      end
    end
  end

  # --- BasicPostSerializer: anonymize user fields across ALL post serializers ---
  # Covers PostSerializer, SearchPostSerializer, PostWordpressSerializer

  BasicPostSerializer.class_eval do
    alias_method :original_basic_username, :username
    def username
      return original_basic_username if !SiteSetting.anonymous_post_enabled
      if AnonymousPostHelper.anon_post_by_id?(object.id) &&
         !AnonymousPostHelper.can_reveal?(scope) &&
         scope.user&.id != object.user_id
        AnonymousPostHelper.anon_username
      else
        original_basic_username
      end
    end

    alias_method :original_basic_name, :name
    def name
      return original_basic_name if !SiteSetting.anonymous_post_enabled
      if AnonymousPostHelper.anon_post_by_id?(object.id) &&
         !AnonymousPostHelper.can_reveal?(scope) &&
         scope.user&.id != object.user_id
        I18n.t("js.anonymous_post.anonymous_name")
      else
        original_basic_name
      end
    end

    alias_method :original_basic_avatar_template, :avatar_template
    def avatar_template
      return original_basic_avatar_template if !SiteSetting.anonymous_post_enabled
      if AnonymousPostHelper.anon_post_by_id?(object.id) &&
         !AnonymousPostHelper.can_reveal?(scope) &&
         scope.user&.id != object.user_id
        AnonymousPostHelper.anonymous_user&.avatar_template || AnonymousPostHelper::ANON_AVATAR_FALLBACK
      else
        original_basic_avatar_template
      end
    end
  end

  # --- PostSerializer-specific overrides ---

  add_to_serializer(:post, :is_anonymous_post) do
    object.custom_fields["is_anonymous_post"].to_i
  end

  add_to_serializer(:post, :display_username) do
    if SiteSetting.anonymous_post_enabled &&
       AnonymousPostHelper.anon_post_by_id?(object.id) &&
       !AnonymousPostHelper.can_reveal?(scope) &&
       scope.user&.id != object.user_id
      I18n.t("js.anonymous_post.anonymous_name")
    else
      object.user&.name
    end
  end

  add_to_serializer(:post, :user_id) do
    if SiteSetting.anonymous_post_enabled &&
       AnonymousPostHelper.anon_post_by_id?(object.id) &&
       !AnonymousPostHelper.can_reveal?(scope) &&
       scope.user&.id != object.user_id
      AnonymousPostHelper.anonymous_user&.id
    else
      object.user_id
    end
  end

  # --- BasicPostSerializer: anonymize quoted usernames in cooked HTML ---
  # NOTE: Using class_eval+alias_method (not add_to_serializer) to avoid Discourse's
  # plugin-enabled gating, which would exclude `cooked` from JSON when plugin is
  # disabled in admin, causing toc-processor.js to crash with undefined.includes().

  BasicPostSerializer.class_eval do
    alias_method :_original_cooked, :cooked
    def cooked
      html = _original_cooked
      return html || "" if html.blank?
      return html if !SiteSetting.anonymous_post_enabled
      return html if AnonymousPostHelper.can_reveal?(scope)

      # Anonymize quoted usernames in cooked HTML
      # Quote format: <aside class="quote" data-username="realuser" data-post="N" data-topic="T">
      anon_name = AnonymousPostHelper.anon_username

      html = html.gsub(%r{<aside[^>]*class="quote"[^>]*>.*?</aside>}m) do |quote_block|
        data_username = quote_block[/data-username="([^"]+)"/, 1]
        data_post = quote_block[/data-post="(\d+)"/, 1]
        data_topic = quote_block[/data-topic="(\d+)"/, 1]

        next quote_block unless data_username && data_post && data_topic

        quoted_post = Post.find_by(topic_id: data_topic.to_i, post_number: data_post.to_i)
        if quoted_post && AnonymousPostHelper.anon_post_by_id?(quoted_post.id) &&
           scope.user&.id != quoted_post.user_id
          result = quote_block.gsub(/data-username="[^"]+"/, "data-username=\"#{anon_name}\"")
          result = result.gsub(%r{(<div class="title">\s*<img[^>]*>\s*)#{Regexp.escape(data_username)}(\s*:?\s*</div>)}m) do
            "#{$1}#{anon_name}#{$2}"
          end
          result
        else
          quote_block
        end
      end

      html
    end
  end

  # --- PostSerializer: anonymize reply-to user for anonymous posts ---

  PostSerializer.class_eval do
    alias_method :original_reply_to_user, :reply_to_user
    def reply_to_user
      result = original_reply_to_user
      return result if result.nil?
      return result if !SiteSetting.anonymous_post_enabled
      return result if AnonymousPostHelper.can_reveal?(scope)

      reply_post_number = object.reply_to_post_number
      return result unless reply_post_number

      reply_post = Post.find_by(topic_id: object.topic_id, post_number: reply_post_number)
      if reply_post && AnonymousPostHelper.anon_post_by_id?(reply_post.id) && scope.user&.id != reply_post.user_id
        AnonymousPostHelper.anonymous_user_hash
      else
        result
      end
    end
  end

  # --- TopicView#page_title: anonymize username in browser/crawler <title> tag ---
  # When navigating to a specific post (/t/slug/id/N), Discourse appends
  # "- #N by username" to the page title. This leaks the real author for
  # anonymous posts and anonymous topic owners.

  module ::AnonymousTopicViewExtension
    def page_title
      return super unless SiteSetting.anonymous_post_enabled && @post_number > 1

      post = @topic.posts.find_by(post_number: @post_number)
      return super unless post

      is_anon_post = AnonymousPostHelper.anon_post_by_id?(post.id)
      is_anon_topic_author =
        AnonymousPostHelper.anon_topic?(@topic) && post.user_id == @topic.user_id

      return super unless is_anon_post || is_anon_topic_author

      anon_name = AnonymousPostHelper.anon_username
      title = @topic.title + " - "
      title +=
        if @guardian.can_see_post?(post)
          I18n.t(
            "inline_oneboxer.topic_page_title_post_number_by_user",
            post_number: @post_number,
            username: anon_name,
          )
        else
          I18n.t("inline_oneboxer.topic_page_title_post_number", post_number: @post_number)
        end

      if SiteSetting.topic_page_title_includes_category
        if @topic.category_id != SiteSetting.uncategorized_category_id &&
             @topic.category_id && @topic.category
          title += " - #{@topic.category.name}"
        elsif SiteSetting.tagging_enabled && visible_tags.exists?
          title +=
            " - #{visible_tags.order("tags.#{Tag.topic_count_column(@guardian)} DESC").first.name}"
        end
      end

      title
    end
  end

  TopicView.prepend(AnonymousTopicViewExtension)

  # --- TopicViewSerializer: topic-level fields ---

  add_to_serializer(:topic_view, :is_anonymous_topic) do
    object.topic.custom_fields["is_anonymous_topic"].to_i
  end

  add_to_serializer(:topic_view, :user_id) do
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

  add_to_serializer(:topic_list_item, :is_anonymous_topic) do
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

  # --- PostRevisionSerializer: hide real editor for anonymous posts ---

  PostRevisionSerializer.class_eval do
    alias_method :original_username, :username
    def username
      return original_username if !SiteSetting.anonymous_post_enabled
      if AnonymousPostHelper.anon_post_by_id?(object.post_id) && !AnonymousPostHelper.can_reveal?(scope)
        AnonymousPostHelper.anonymous_user&.username || AnonymousPostHelper.anon_username
      else
        original_username
      end
    end

    alias_method :original_display_username, :display_username
    def display_username
      return original_display_username if !SiteSetting.anonymous_post_enabled
      if AnonymousPostHelper.anon_post_by_id?(object.post_id) && !AnonymousPostHelper.can_reveal?(scope)
        AnonymousPostHelper.anonymous_user&.name || I18n.t("js.anonymous_post.anonymous_name")
      else
        original_display_username
      end
    end

    alias_method :original_avatar_template, :avatar_template
    def avatar_template
      return original_avatar_template if !SiteSetting.anonymous_post_enabled
      if AnonymousPostHelper.anon_post_by_id?(object.post_id) && !AnonymousPostHelper.can_reveal?(scope)
        AnonymousPostHelper.anonymous_user&.avatar_template || AnonymousPostHelper::ANON_AVATAR_FALLBACK
      else
        original_avatar_template
      end
    end
  end

  # --- PostAlerter:  anonymize notifications for anonymous posts ---

  module ::AnonymousPostAlerterExtension
    def create_notification(user, notification_type, post, opts = {})
      if SiteSetting.anonymous_post_enabled && post && AnonymousPostHelper.anon_post?(post)
        anon = AnonymousPostHelper.anonymous_user
        if anon
          opts[:display_username] = anon.username
          opts[:acting_user_id] = anon.id
        else
          opts[:display_username] = AnonymousPostHelper.anon_username
        end
      end
      super(user, notification_type, post, opts)
    end
  end

  PostAlerter.prepend(AnonymousPostAlerterExtension)

  # --- discourse-solved: anonymize "accepted solution" notifications ---

  on(:accepted_solution) do |post|
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

  # --- UserSummary: hide anonymous posts/topics from profile summary ---

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

  # --- UserAction: hide anonymous posts from other users' activity ---

  UserAction.class_eval do
    class << self
      alias_method :original_stream, :stream

      def stream(opts = {})
        result = original_stream(opts)

        guardian = opts[:guardian]
        acting_user_id = opts[:user_id]

        if SiteSetting.anonymous_post_enabled && guardian && !AnonymousPostHelper.can_reveal?(guardian) && guardian.user&.id != acting_user_id
          result = result.reject do |action|
            should_hide = false

            # Check if the action's post itself is anonymous
            if action.respond_to?(:post_id) && action.post_id.present?
              should_hide = AnonymousPostHelper.anon_post_by_id?(action.post_id)
            end

            # Check if the action is in an anonymous topic owned by the profile user
            if !should_hide && action.respond_to?(:topic_id) && action.topic_id.present?
              should_hide = TopicCustomField.exists?(topic_id: action.topic_id, name: "is_anonymous_topic", value: "1") &&
                            Topic.where(id: action.topic_id, user_id: acting_user_id).exists?
            end

            should_hide
          end
        end

        result
      end
    end
  end

  # --- TopicQuery: hide anonymous topics from "Темы" tab on user profile ---

  module ::AnonymousTopicQueryExtension
    def list_topics_by(user)
      result = super(user)
      return result if !SiteSetting.anonymous_post_enabled
      # If the viewer is not the profile owner and not in reveal groups, exclude anonymous topics
      if @guardian && !AnonymousPostHelper.can_reveal?(@guardian) && @guardian.user&.id != user.id
        anon_topic_ids = TopicCustomField.where(name: "is_anonymous_topic", value: "1").pluck(:topic_id)
        if anon_topic_ids.present?
          result.topics.reject! { |t| anon_topic_ids.include?(t.id) }
        end
      end
      result
    end
  end

  TopicQuery.prepend(AnonymousTopicQueryExtension)

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

  # --- UserCardSerializer: hide message button for anonymous user ---
  # UserSerializer inherits from UserCardSerializer, so this covers both
  # user card popup and full profile page

  UserCardSerializer.class_eval do
    alias_method :original_can_send_private_message_to_user, :can_send_private_message_to_user
    def can_send_private_message_to_user
      if SiteSetting.anonymous_post_enabled
        anon = AnonymousPostHelper.anonymous_user
        return false if anon && object.id == anon.id
      end
      original_can_send_private_message_to_user
    end
  end

  # --- Flag PM: redirect "send message" for anonymous posts to moderators ---

  register_post_action_notify_user_handler(Proc.new { |user, post, message|
    if SiteSetting.anonymous_post_enabled &&
       post && AnonymousPostHelper.anon_post_by_id?(post.id) &&
       !AnonymousPostHelper.can_reveal?(Guardian.new(user))

      anon_user = AnonymousPostHelper.anonymous_user
      real_user = post.user
      next nil unless anon_user && real_user  # Allow default if no anon user configured

      title = I18n.t(
        "post_action_types.notify_user.email_title",
        title: post.topic.title,
        locale: SiteSetting.default_locale,
        default: I18n.t("post_action_types.illegal.email_title"),
      )

      body = I18n.t(
        "post_action_types.notify_user.email_body",
        message: message,
        link: "#{Discourse.base_url}#{post.url}",
        locale: SiteSetting.default_locale,
        default: I18n.t("post_action_types.illegal.email_body"),
      )

      truncated_title = title.truncate(SiteSetting.max_topic_title_length, separator: /\s/)

      # 1. PM from sender → anonymous user (sender sees "anonymous" in sent messages)
      PostCreator.create!(
        user,
        archetype: Archetype.private_message,
        subtype: TopicSubtype.notify_user,
        title: truncated_title,
        raw: body,
        target_usernames: anon_user.username,
      )

      # 2. System PM → real user (real user gets the actual message)
      PostCreator.create!(
        Discourse.system_user,
        archetype: Archetype.private_message,
        subtype: TopicSubtype.notify_user,
        title: truncated_title,
        raw: body,
        target_usernames: real_user.username,
      )

      false  # Prevent default PM to real author
    end
  })

  # --- discourse-solved: hide anonymous solved posts from "Решённые" tab ---

  if defined?(DiscourseSolved::SolvedTopicsController)
    module ::AnonymousSolvedTopicsExtension
      def by_user
        params.require(:username)
        target_user = User.find_by(username: params[:username])

        # If viewing someone else's profile and not in reveal groups, filter anonymous posts
        if target_user && current_user&.id != target_user.id &&
           !AnonymousPostHelper.can_reveal?(guardian)
          anon_post_ids = PostCustomField.where(name: "is_anonymous_post", value: "1").pluck(:post_id)
          if anon_post_ids.present?
            # Re-implement the query with additional filter
            user =
              fetch_user_from_params(
                include_inactive:
                  current_user.try(:staff?) || (current_user && SiteSetting.show_inactive_accounts),
              )
            raise Discourse::NotFound unless guardian.public_can_see_profiles?
            raise Discourse::NotFound unless guardian.can_see_profile?(user)

            offset = [0, params[:offset].to_i].max
            limit = params.fetch(:limit, 30).to_i

            posts =
              Post
                .joins(
                  "INNER JOIN discourse_solved_solved_topics ON discourse_solved_solved_topics.answer_post_id = posts.id",
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
                .order("discourse_solved_solved_topics.created_at DESC")
                .offset(offset)
                .limit(limit)

            render_serialized(posts, DiscourseSolved::SolvedPostSerializer, root: "user_solved_posts")
            return
          end
        end

        super
      end
    end

    DiscourseSolved::SolvedTopicsController.prepend(AnonymousSolvedTopicsExtension)
  end
end
