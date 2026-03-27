# frozen_string_literal: true

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
