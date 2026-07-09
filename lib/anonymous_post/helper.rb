# frozen_string_literal: true

module ::AnonymousPostHelper
  ANON_AVATAR_FALLBACK = "/letter_avatar_proxy/v4/letter/a/b3b5b3/{size}.png"
  RAW_QUOTE_PATTERN = /\[quote=(["'])(.*?)\1\]/.freeze

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
    anonymous_post_flag?(post_obj)
  end

  # Safe check via direct DB query — avoids NotPreloadedError
  def self.anon_post_by_id?(post_id)
    PostCustomField.exists?(post_id: post_id, name: "is_anonymous_post", value: "1")
  end

  def self.preloaded_custom_field?(record, name)
    return false unless record.respond_to?(:custom_field_preloaded?)

    record.custom_field_preloaded?(name)
  rescue StandardError
    false
  end

  def self.anonymous_post_flag?(post_obj)
    return false unless post_obj

    if preloaded_custom_field?(post_obj, "is_anonymous_post")
      post_obj.custom_fields["is_anonymous_post"].to_i == 1
    else
      anon_post_by_id?(post_obj.id)
    end
  rescue StandardError
    anon_post_by_id?(post_obj.id)
  end

  def self.anon_topic_by_id?(topic_id)
    TopicCustomField.exists?(topic_id: topic_id, name: "is_anonymous_topic", value: "1")
  end

  def self.anon_topic?(topic_obj)
    return false unless topic_obj

    if preloaded_custom_field?(topic_obj, "is_anonymous_topic")
      topic_obj.custom_fields["is_anonymous_topic"].to_i == 1
    else
      anon_topic_by_id?(topic_obj.id)
    end
  rescue StandardError
    anon_topic_by_id?(topic_obj.id)
  end

  def self.anonymous_topic_owner_post?(post_obj, topic_obj = nil)
    return false unless post_obj

    topic_obj ||= post_obj.topic if post_obj.respond_to?(:topic)
    topic_id = topic_obj&.id || post_obj.try(:topic_id)
    return false if topic_id.blank?

    topic_user_id = topic_obj&.user_id || Topic.where(id: topic_id).pick(:user_id)

    topic_user_id == post_obj.user_id && anon_topic_by_id?(topic_id)
  end

  def self.anonymous_author_post?(post_obj, topic_obj = nil)
    return false unless post_obj

    cache_key = :@anonymous_post_author
    return post_obj.instance_variable_get(cache_key) if post_obj.instance_variable_defined?(cache_key)

    result = anonymous_post_flag?(post_obj) || anonymous_topic_owner_post?(post_obj, topic_obj)
    post_obj.instance_variable_set(cache_key, result)
    result
  rescue StandardError
    anon_post_by_id?(post_obj.id) || anonymous_topic_owner_post?(post_obj, topic_obj)
  end

  def self.mask_author?(scope, post_obj, force: false, exempt_author: true)
    return false unless SiteSetting.anonymous_post_enabled
    return false unless post_obj

    unless force
      return false unless hide_real_author?(scope)
      return false if exempt_author && scope&.user&.id == post_obj.user_id
    end

    anonymous_author_post?(post_obj)
  end

  def self.anonymous_author_post_ids(posts, topic_obj = nil)
    posts_array = Array(posts).compact
    return Set.new if posts_array.empty?

    post_ids = posts_array.filter_map { |post| post.id if post.respond_to?(:id) }
    return Set.new if post_ids.empty?

    explicit_anon_post_ids =
      PostCustomField
        .where(post_id: post_ids, name: "is_anonymous_post", value: "1")
        .pluck(:post_id)
        .to_set

    topic_ids = posts_array.filter_map { |post| post.topic_id if post.respond_to?(:topic_id) }.uniq
    anon_topic_ids =
      TopicCustomField
        .where(topic_id: topic_ids, name: "is_anonymous_topic", value: "1")
        .pluck(:topic_id)
        .to_set

    topic_owner_ids =
      if topic_obj && anon_topic_ids.include?(topic_obj.id)
        { topic_obj.id => topic_obj.user_id }
      elsif anon_topic_ids.any?
        Topic.where(id: anon_topic_ids.to_a).pluck(:id, :user_id).to_h
      else
        {}
      end

    posts_array.each_with_object(Set.new) do |post, result|
      result << post.id if explicit_anon_post_ids.include?(post.id)

      owner_id = topic_owner_ids[post.topic_id]
      result << post.id if owner_id && owner_id == post.user_id
    end
  end

  def self.hide_real_author?(scope)
    SiteSetting.anonymous_post_enabled && !(scope && can_reveal?(scope))
  end

  def self.anonymous_avatar_url(size = 45)
    (anonymous_user&.avatar_template || ANON_AVATAR_FALLBACK).gsub("{size}", size.to_s)
  end

  def self.anonymize_raw_quotes(text)
    return text unless text.respond_to?(:include?) && text.respond_to?(:gsub)
    return text if text.blank? || !text.include?("[quote=")

    targets = anon_quote_targets(raw_quote_pairs(text))
    return text if targets.empty?

    text.gsub(RAW_QUOTE_PATTERN) do |match|
      quote_char = Regexp.last_match(1)
      header = Regexp.last_match(2)
      _username, metadata = header.split(",", 2)
      next match if metadata.blank?

      topic_id = metadata[/\btopic:(\d+)/, 1]
      post_number = metadata[/\bpost:(\d+)/, 1]
      next match if topic_id.blank? || post_number.blank?
      next match unless targets.include?([topic_id.to_i, post_number.to_i])

      %([quote=#{quote_char}#{anon_username},#{metadata}#{quote_char}])
    end
  end

  def self.raw_quote_pairs(text)
    pairs = []

    text.scan(RAW_QUOTE_PATTERN) do
      header = Regexp.last_match(2)
      _username, metadata = header.split(",", 2)
      next if metadata.blank?

      topic_id = metadata[/\btopic:(\d+)/, 1].to_i
      post_number = metadata[/\bpost:(\d+)/, 1].to_i
      next unless topic_id.positive? && post_number.positive?

      pairs << [topic_id, post_number]
    end

    pairs
  end

  def self.anon_quote_targets(pairs)
    normalized_pairs =
      Array(pairs)
        .filter_map do |topic_id, post_number|
          topic_id = topic_id.to_i
          post_number = post_number.to_i
          [topic_id, post_number] if topic_id.positive? && post_number.positive?
        end
        .uniq

    return Set.new if normalized_pairs.empty?

    tuple_sql = normalized_pairs.map { |topic_id, post_number| "(#{topic_id}, #{post_number})" }.join(", ")

    posts =
      Post
        .where("(topic_id, post_number) IN (#{tuple_sql})")
        .select(:id, :topic_id, :post_number, :user_id)
        .to_a

    return Set.new if posts.empty?

    anonymous_author_post_ids(posts).each_with_object(Set.new) do |post_id, result|
      post = posts.find { |candidate| candidate.id == post_id }
      result << [post.topic_id, post.post_number] if post
    end
  end

  def self.anonymize_cooked_quotes(html)
    return html if html.blank? || !html.include?("aside")

    fragment =
      if defined?(Nokogiri::HTML5)
        Nokogiri::HTML5.fragment(html)
      else
        Nokogiri::HTML.fragment(html)
      end

    quotes = fragment.css("aside.quote")
    return html if quotes.empty?

    quote_pairs =
      quotes.filter_map do |quote|
        data_topic = quote["data-topic"].to_i
        data_post = quote["data-post"].to_i
        [data_topic, data_post] if data_topic.positive? && data_post.positive?
      end

    targets = anon_quote_targets(quote_pairs)
    return html if targets.empty?

    anon_name = anon_username
    anon_avatar_url = anonymous_avatar_url
    changed = false

    quotes.each do |quote|
      data_username = quote["data-username"]
      data_post = quote["data-post"].to_i
      data_topic = quote["data-topic"].to_i

      next if data_username.blank? || data_post <= 0 || data_topic <= 0
      next unless targets.include?([data_topic, data_post])

      quote["data-username"] = anon_name
      quote["data-user-card"] = anon_name if quote["data-user-card"].present?

      quote.css("[data-user-card]").each do |node|
        node["data-user-card"] = anon_name if node["data-user-card"] == data_username
      end

      title = quote.at_css("div.title")
      if title
        title.traverse do |node|
          next unless node.text?

          node.content = node.content.gsub(data_username, anon_name)
        end

        title.css("img").each do |img|
          img["src"] = anon_avatar_url if img["src"].present?
          img["alt"] = anon_name if img["alt"].present?
          img["title"] = anon_name if img["title"].present?
          img.remove_attribute("srcset")
        end

        title.css("a").each do |link|
          link["href"] = "/u/#{anon_name}" if link["href"].to_s.include?("/u/#{data_username}")
        end
      end

      changed = true
    end

    changed ? fragment.to_html : html
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
