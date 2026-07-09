# frozen_string_literal: true

# --- PostAlerter: anonymize notifications for anonymous posts ---

module ::AnonymousNotificationData
  USERNAME_KEYS = %w[display_username username original_username acting_username].freeze
  NAME_KEYS = %w[display_name name original_name acting_name].freeze
  USER_ID_KEYS = %w[acting_user_id user_id original_user_id].freeze
  TEXT_KEYS = %w[excerpt original_excerpt post_excerpt raw cooked message body text description].freeze

  def self.set_key(data, key, value, key_style = nil)
    string_key = key.to_s
    symbol_key = string_key.to_sym

    if data.key?(string_key)
      data[string_key] = value
    elsif data.key?(symbol_key)
      data[symbol_key] = value
    elsif key_style == :symbol
      data[symbol_key] = value
    elsif key_style == :string
      data[string_key] = value
    elsif data.keys.any? { |k| k.is_a?(Symbol) }
      data[symbol_key] = value
    else
      data[string_key] = value
    end
  end

  def self.apply!(data, key_style: nil)
    anon = AnonymousPostHelper.anonymous_user_hash
    anonymize_text_fields!(data)

    USERNAME_KEYS.each do |key|
      set_key(data, key, anon[:username], key_style) if data.key?(key) || data.key?(key.to_sym)
    end

    NAME_KEYS.each do |key|
      set_key(data, key, anon[:name], key_style) if data.key?(key) || data.key?(key.to_sym)
    end

    USER_ID_KEYS.each do |key|
      set_key(data, key, anon[:id], key_style) if data.key?(key) || data.key?(key.to_sym)
    end

    set_key(data, "display_username", anon[:username], key_style)
    set_key(data, "display_name", anon[:name], key_style)
    set_key(data, "acting_user_id", anon[:id], key_style)
    set_key(data, "user_id", anon[:id], key_style)
    data
  end

  def self.anonymize_text_fields!(data)
    changed = false

    TEXT_KEYS.each do |key|
      [key, key.to_sym].each do |candidate|
        next unless data.key?(candidate) && data[candidate].present?

        original = data[candidate].to_s
        anonymized =
          if original.include?("<aside")
            AnonymousPostHelper.anonymize_cooked_quotes(original)
          else
            AnonymousPostHelper.anonymize_raw_quotes(original)
          end
        next if anonymized == original

        data[candidate] = anonymized
        changed = true
      end
    end

    changed
  end

  def self.payload_key_style(data)
    data.keys.any? { |key| key.is_a?(Symbol) } ? :symbol : :string
  end

  def self.excerpt_from_cooked(html)
    return nil if html.blank?

    max_length = SiteSetting.respond_to?(:post_excerpt_maxlength) ? SiteSetting.post_excerpt_maxlength : 300

    if defined?(ExcerptParser)
      begin
        return ExcerptParser.get_excerpt(html, max_length, text_entities: true)
      rescue ArgumentError
        return ExcerptParser.get_excerpt(html, max_length)
      end
    end

    return PrettyText.excerpt(html, max_length) if defined?(PrettyText)

    nil
  rescue StandardError => e
    Rails.logger.warn("[AnonymousPost] notification excerpt anonymization failed: #{e.message}")
    nil
  end

  def self.anonymous_context?(post, actor_user_id = nil)
    return true if AnonymousPostHelper.anonymous_author_post?(post)

    topic = post&.topic
    return false unless topic && actor_user_id

    AnonymousPostHelper.user_has_anon_posts_in_topic?(actor_user_id, topic.id) ||
      (AnonymousPostHelper.anon_topic?(topic) && topic.user_id == actor_user_id)
  end

  def self.post_from_notification(notification, data)
    topic_id = data["topic_id"] || data[:topic_id] || notification.try(:topic_id)
    post_number = data["post_number"] || data[:post_number] || notification.try(:post_number)

    return nil if topic_id.blank? || post_number.blank?

    Post.find_by(topic_id: topic_id, post_number: post_number)
  end

  def self.actor_user_id(data)
    USER_ID_KEYS.each do |key|
      value = data[key] || data[key.to_sym]
      return value.to_i if value.to_i.positive?
    end

    username = USERNAME_KEYS.filter_map { |key| data[key] || data[key.to_sym] }.first
    User.find_by(username: username)&.id
  end
end

module ::AnonymousPostAlerterExtension
  def create_notification(user, notification_type, post, opts = {})
    if SiteSetting.anonymous_post_enabled && post
      if AnonymousPostHelper.anonymous_author_post?(post)
        # Пост сам анонимный — анонимизируем отправителя
        AnonymousNotificationData.apply!(opts, key_style: :symbol)
      elsif (opts[:acting_user_id] || opts[:user_id]).present?
        # acting_user поставил лайк/реакцию, но сам является анонимным автором в этой теме.
        # discourse-reactions передаёт user_id (не acting_user_id) — проверяем оба ключа.
        acting_user_id = opts[:acting_user_id] || opts[:user_id]
        topic = post.topic
        if topic
          is_anon_in_topic =
            AnonymousPostHelper.user_has_anon_posts_in_topic?(acting_user_id, topic.id) ||
            (AnonymousPostHelper.anon_topic?(topic) && topic.user_id == acting_user_id)
          if is_anon_in_topic
            AnonymousNotificationData.apply!(opts, key_style: :symbol)
          end
        end
      end
    end
    super(user, notification_type, post, opts)
  end
end

module AnonymousPost
  module Notifications
    def self.apply!(plugin)
      PostAlerter.prepend(AnonymousPostAlerterExtension)

      if defined?(NotificationSerializer)
        NotificationSerializer.class_eval do
          alias_method :original_anonymous_post_data, :data
          def data
            result = original_anonymous_post_data
            return result if result.nil?
            return result unless SiteSetting.anonymous_post_enabled

            was_json = result.is_a?(String)
            parsed =
              if was_json
                JSON.parse(result)
              elsif result.respond_to?(:deep_dup)
                result.deep_dup
              else
                result.dup
              end

            return result unless parsed.is_a?(Hash)

            text_changed = AnonymousNotificationData.anonymize_text_fields!(parsed)
            post = AnonymousNotificationData.post_from_notification(object, parsed)
            actor_user_id = AnonymousNotificationData.actor_user_id(parsed)

            unless AnonymousNotificationData.anonymous_context?(post, actor_user_id)
              return text_changed ? (was_json ? parsed.to_json : parsed) : result
            end

            key_style = was_json ? :string : AnonymousNotificationData.payload_key_style(parsed)
            AnonymousNotificationData.apply!(parsed, key_style: key_style)
            was_json ? parsed.to_json : parsed
          rescue JSON::ParserError
            result
          end
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

      plugin.on(:pre_notification_alert) do |_user, payload|
        next unless SiteSetting.anonymous_post_enabled
        next unless payload.is_a?(Hash)

        topic_id = payload[:topic_id] || payload["topic_id"]
        post_number = payload[:post_number] || payload["post_number"]
        next if topic_id.blank? || post_number.blank?

        post = Post.find_by(topic_id: topic_id.to_i, post_number: post_number.to_i)
        next unless post

        key_style = AnonymousNotificationData.payload_key_style(payload)

        if AnonymousPostHelper.anonymous_author_post?(post)
          AnonymousNotificationData.set_key(payload, "username", AnonymousPostHelper.anon_username, key_style)
          AnonymousNotificationData.set_key(payload, "display_username", AnonymousPostHelper.anon_username, key_style)
        end

        next unless (payload[:excerpt] || payload["excerpt"]).present?
        next unless post.cooked.to_s.include?("aside")

        anonymized_cooked = AnonymousPostHelper.anonymize_cooked_quotes(post.cooked)
        next if anonymized_cooked == post.cooked

        excerpt = AnonymousNotificationData.excerpt_from_cooked(anonymized_cooked)
        AnonymousNotificationData.set_key(payload, "excerpt", excerpt, key_style) if excerpt.present?
      end

      # --- Flag PM: redirect "send message" for anonymous posts to moderators ---

      plugin.register_post_action_notify_user_handler(Proc.new { |user, post, message|
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
    end
  end
end
