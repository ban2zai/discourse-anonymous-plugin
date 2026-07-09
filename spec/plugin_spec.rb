# frozen_string_literal: true

require "rails_helper"

describe "anonymous post privacy" do
  fab!(:anon_user) { Fabricate(:user, username: "anonymous", name: "Anonymous") }
  fab!(:author) { Fabricate(:user, username: "doskochda", name: "DoskochDA") }
  fab!(:viewer) { Fabricate(:user, username: "regularviewer") }
  fab!(:admin) { Fabricate(:admin) }
  fab!(:category)

  before do
    SiteSetting.anonymous_post_enabled = true
    SiteSetting.anonymous_post_user = anon_user.username
    AnonymousPostHelper.reset_cache!
  end

  def guardian(user)
    Guardian.new(user)
  end

  def mark_anonymous_topic(topic)
    topic.custom_fields["is_anonymous_topic"] = 1
    topic.save_custom_fields(true)
    topic.reload
  end

  def mark_anonymous_post(post)
    post.custom_fields["is_anonymous_post"] = 1
    post.save_custom_fields(true)
    post.reload
  end

  def fabricate_post(topic:, user:, post_number:, cooked: "<p>Post text</p>", reply_to_post_number: nil)
    post =
      Fabricate(
        :post,
        topic: topic,
        user: user,
        post_number: post_number,
        reply_to_post_number: reply_to_post_number,
      )
    post.update_columns(cooked: cooked)
    post.reload
  end

  def anonymous_topic_with_owner_posts
    topic = Fabricate(:topic, user: author, category: category)
    mark_anonymous_topic(topic)

    first_post = fabricate_post(topic: topic, user: author, post_number: 1)
    anonymous_reply = fabricate_post(topic: topic, user: author, post_number: 2)
    mark_anonymous_post(anonymous_reply)

    [topic, first_post, anonymous_reply]
  end

  def quote_html(topic, quoted_post)
    <<~HTML
      <aside class="quote" data-username="#{author.username}" data-user-card="#{author.username}" data-post="#{quoted_post.post_number}" data-topic="#{topic.id}">
        <div class="title">
          <img src="/user_avatar/test/#{author.username}/45/1.png" alt="#{author.username}" title="#{author.username}">
          <a href="/u/#{author.username}" data-user-card="#{author.username}">#{author.username}</a>:
        </div>
        <blockquote><p>Quoted text</p></blockquote>
      </aside>
      <p>Reply text</p>
    HTML
  end

  def quote_raw(topic, quoted_post)
    %([quote="#{author.username}, post:#{quoted_post.post_number}, topic:#{topic.id}"]Quoted text[/quote])
  end

  def serialize_cooked(post, user)
    PostSerializer.new(post, scope: guardian(user), root: false).cooked
  end

  def expect_no_author_leak(payload)
    text = payload.is_a?(String) ? payload : payload.to_json

    expect(text).to include(anon_user.username)
    expect(text).not_to include(author.username)
    expect(text).not_to include(author.name)
    expect(text).not_to include("/#{author.username}/")
  end

  def expect_author_visible(payload)
    text = payload.is_a?(String) ? payload : payload.to_json

    expect(text).to include(author.username)
  end

  def stubbed_serializer(klass, object:, scope:)
    serializer = klass.allocate
    allow(serializer).to receive(:object).and_return(object)
    allow(serializer).to receive(:scope).and_return(scope)
    serializer
  end

  describe "shared anonymous author classification" do
    it "treats explicitly anonymous posts and anonymous topic owner posts as anonymous author payloads" do
      topic, first_post, anonymous_reply = anonymous_topic_with_owner_posts
      normal_reply = fabricate_post(topic: topic, user: viewer, post_number: 3)

      expect(AnonymousPostHelper.anonymous_author_post?(anonymous_reply)).to eq(true)
      expect(AnonymousPostHelper.anonymous_author_post?(first_post)).to eq(true)
      expect(AnonymousPostHelper.anonymous_author_post?(normal_reply)).to eq(false)
      expect(AnonymousPostHelper.hide_real_author?(guardian(viewer))).to eq(true)
      expect(AnonymousPostHelper.hide_real_author?(guardian(admin))).to eq(false)
    end

    it "memoizes anonymous author classification on the post object" do
      _topic, _first_post, anonymous_reply = anonymous_topic_with_owner_posts

      expect(anonymous_reply.instance_variable_defined?(:@anonymous_post_author)).to eq(false)
      expect(AnonymousPostHelper.anonymous_author_post?(anonymous_reply)).to eq(true)
      expect(anonymous_reply.instance_variable_get(:@anonymous_post_author)).to eq(true)
    end

    it "classifies raw quote targets in one batch" do
      topic, first_post, anonymous_reply = anonymous_topic_with_owner_posts
      normal_reply = fabricate_post(topic: topic, user: viewer, post_number: 3)

      targets =
        AnonymousPostHelper.anon_quote_targets(
          [
            [topic.id, first_post.post_number],
            [topic.id, anonymous_reply.post_number],
            [topic.id, normal_reply.post_number],
          ],
        )

      expect(targets).to include([topic.id, first_post.post_number])
      expect(targets).to include([topic.id, anonymous_reply.post_number])
      expect(targets).not_to include([topic.id, normal_reply.post_number])
    end

    it "anonymizes raw markdown quotes that point to anonymous author posts" do
      topic, first_post, anonymous_reply = anonymous_topic_with_owner_posts
      raw =
        [
          quote_raw(topic, first_post),
          %([quote="#{author.username}, post:#{anonymous_reply.post_number}, topic:#{topic.id}, full:true"]Reply[/quote]),
        ].join("\n")

      anonymized = AnonymousPostHelper.anonymize_raw_quotes(raw)

      expect(anonymized).to include(%([quote="#{anon_user.username}, post:#{first_post.post_number}, topic:#{topic.id}"]))
      expect(anonymized).to include(%([quote="#{anon_user.username}, post:#{anonymous_reply.post_number}, topic:#{topic.id}, full:true"]))
      expect(anonymized).not_to include(author.username)
    end

    it "does not rewrite raw markdown quotes that point to non-anonymous posts" do
      topic = Fabricate(:topic, user: author, category: category)
      quoted_post = fabricate_post(topic: topic, user: author, post_number: 1)

      expect(AnonymousPostHelper.anonymize_raw_quotes(quote_raw(topic, quoted_post))).to include(author.username)
    end
  end

  describe "post serializers" do
    it "anonymizes post author fields for the anonymous author and regular users" do
      _topic, first_post, anonymous_reply = anonymous_topic_with_owner_posts

      [first_post, anonymous_reply].each do |post|
        author_serializer = PostSerializer.new(post, scope: guardian(author), root: false)

        expect(author_serializer.username).to eq(author.username)
        expect(author_serializer.name).to eq(author.name)
        expect(author_serializer.display_username).to eq(author.name)
        expect(author_serializer.user_id).to eq(author.id)
        expect(author_serializer.avatar_template).to eq(author.avatar_template)

        viewer_serializer = PostSerializer.new(post, scope: guardian(viewer), root: false)

        expect(viewer_serializer.username).to eq(anon_user.username)
        expect(viewer_serializer.name).to eq("Anonymous")
        expect(viewer_serializer.display_username).to eq("Anonymous")
        expect(viewer_serializer.user_id).to eq(anon_user.id)
        expect(viewer_serializer.avatar_template).to eq(anon_user.avatar_template)
      end
    end

    it "keeps post author fields visible for admins" do
      _topic, _first_post, anonymous_reply = anonymous_topic_with_owner_posts
      serializer = PostSerializer.new(anonymous_reply, scope: guardian(admin), root: false)

      expect(serializer.username).to eq(author.username)
      expect(serializer.user_id).to eq(author.id)
    end

    it "anonymizes a self quote of an anonymous reply for the author and regular users" do
      topic, _first_post, quoted_post = anonymous_topic_with_owner_posts
      quoting_post =
        fabricate_post(
          topic: topic,
          user: author,
          post_number: 3,
          cooked: quote_html(topic, quoted_post),
        )
      mark_anonymous_post(quoting_post)

      [author, viewer].each do |user|
        cooked = serialize_cooked(quoting_post, user)

        expect_no_author_leak(cooked)
        expect(cooked).to include(%(data-username="#{anon_user.username}"))
        expect(cooked).to include(%(data-user-card="#{anon_user.username}"))
        expect(cooked).to include(%(href="/u/#{anon_user.username}"))
        expect(cooked).not_to include(%(data-username="#{author.username}"))
        expect(cooked).not_to include(%(data-user-card="#{author.username}"))
      end
    end

    it "anonymizes quotes of anonymous topic owner posts without requiring a post custom field" do
      topic, first_post, _anonymous_reply = anonymous_topic_with_owner_posts
      quoting_post =
        fabricate_post(
          topic: topic,
          user: viewer,
          post_number: 3,
          cooked: quote_html(topic, first_post),
        )

      expect_no_author_leak(serialize_cooked(quoting_post, viewer))
    end

    it "keeps real quote data visible for admins" do
      topic, _first_post, quoted_post = anonymous_topic_with_owner_posts
      quoting_post =
        fabricate_post(
          topic: topic,
          user: author,
          post_number: 3,
          cooked: quote_html(topic, quoted_post),
        )

      expect_author_visible(serialize_cooked(quoting_post, admin))
    end

    it "does not rewrite quotes of non-anonymous posts" do
      topic = Fabricate(:topic, user: author, category: category)
      quoted_post = fabricate_post(topic: topic, user: author, post_number: 1)
      quoting_post =
        fabricate_post(
          topic: topic,
          user: viewer,
          post_number: 2,
          cooked: quote_html(topic, quoted_post),
        )

      expect_author_visible(serialize_cooked(quoting_post, viewer))
    end

    it "anonymizes raw quote usernames when raw post content is serialized" do
      skip "PostSerializer#raw is not available in this Discourse version" unless PostSerializer.method_defined?(:raw)

      topic, first_post, _anonymous_reply = anonymous_topic_with_owner_posts
      quoting_post =
        fabricate_post(
          topic: topic,
          user: author,
          post_number: 3,
        )
      quoting_post.update_columns(raw: "#{quote_raw(topic, first_post)} Reply text")

      [author, viewer].each do |user|
        raw = PostSerializer.new(quoting_post, scope: guardian(user), root: false).raw

        expect(raw).to include(%([quote="#{anon_user.username}, post:#{first_post.post_number}, topic:#{topic.id}"]))
        expect(raw).not_to include(author.username)
      end
    end

    it "anonymizes reply_to_user for anonymous author posts" do
      topic, _first_post, replied_to_post = anonymous_topic_with_owner_posts
      reply =
        fabricate_post(
          topic: topic,
          user: author,
          post_number: 3,
          reply_to_post_number: replied_to_post.post_number,
        )

      [author, viewer].each do |user|
        reply_to_user =
          PostSerializer.new(reply, scope: guardian(user), root: false).reply_to_user.with_indifferent_access

        expect(reply_to_user[:username]).to eq(anon_user.username)
        expect(reply_to_user[:name]).to eq(anon_user.name)
        expect(reply_to_user[:id]).to eq(anon_user.id)
      end
    end

    it "anonymizes post revision author fields" do
      _topic, _first_post, anonymous_reply = anonymous_topic_with_owner_posts
      revision = OpenStruct.new(post_id: anonymous_reply.id)
      serializer = stubbed_serializer(PostRevisionSerializer, object: revision, scope: guardian(author))

      expect(serializer.username).to eq(anon_user.username)
      expect(serializer.display_username).to eq(anon_user.name)
      expect(serializer.avatar_template).to eq(anon_user.avatar_template)
    end
  end

  describe "topic serializers" do
    it "anonymizes topic owner fields in topic view details" do
      topic, _first_post, _anonymous_reply = anonymous_topic_with_owner_posts
      details = OpenStruct.new(topic: topic)
      author_serializer = stubbed_serializer(TopicViewDetailsSerializer, object: details, scope: guardian(author))
      allow(author_serializer).to receive(:original_created_by).and_return(author)
      allow(author_serializer).to receive(:original_participants).and_return([author, viewer])

      expect(author_serializer.created_by.username).to eq(author.username)
      expect(author_serializer.participants.map(&:username)).to include(author.username)

      viewer_serializer = stubbed_serializer(TopicViewDetailsSerializer, object: details, scope: guardian(viewer))
      allow(viewer_serializer).to receive(:original_created_by).and_return(author)
      allow(viewer_serializer).to receive(:original_participants).and_return([author, viewer])

      created_by = viewer_serializer.created_by
      participants = viewer_serializer.participants
      usernames =
        participants.map do |participant|
          participant.respond_to?(:username) ? participant.username : participant[:user].username
        end

      expect(created_by.username).to eq(anon_user.username)
      expect(usernames).to include(anon_user.username)
      expect(usernames).not_to include(author.username)
    end

    it "anonymizes last_poster for anonymous topic owner activity" do
      topic, _first_post, anonymous_reply = anonymous_topic_with_owner_posts
      topic.update_columns(last_posted_at: anonymous_reply.created_at)
      details = OpenStruct.new(topic: topic)
      serializer = stubbed_serializer(TopicViewDetailsSerializer, object: details, scope: guardian(viewer))

      expect(serializer.last_poster.username).to eq(anon_user.username)
    end

    it "hides topic user_id for anonymous topics from regular users but keeps it for the topic owner" do
      topic, _first_post, _anonymous_reply = anonymous_topic_with_owner_posts
      topic_view = OpenStruct.new(topic: topic)

      author_serializer = TopicViewSerializer.new(topic_view, scope: guardian(author), root: false)
      viewer_serializer = TopicViewSerializer.new(topic_view, scope: guardian(viewer), root: false)

      expect(author_serializer.user_id).to eq(author.id)
      expect(viewer_serializer.user_id).to eq(nil)
    end

    it "serializes anonymous topic flags without requiring preloaded custom fields" do
      topic, _first_post, _anonymous_reply = anonymous_topic_with_owner_posts
      topic_view = OpenStruct.new(topic: topic)

      allow(topic).to receive(:custom_field_preloaded?).with("is_anonymous_topic").and_return(false)
      allow(topic).to receive(:custom_fields).and_raise(StandardError, "custom fields were not preloaded")

      expect(TopicViewSerializer.new(topic_view, scope: guardian(viewer), root: false).is_anonymous_topic).to eq(1)
      expect(TopicListItemSerializer.new(topic, scope: guardian(viewer), root: false).is_anonymous_topic).to eq(1)
    end

    it "anonymizes topic list posters" do
      topic, _first_post, _anonymous_reply = anonymous_topic_with_owner_posts
      poster = OpenStruct.new(user: author)
      author_serializer = stubbed_serializer(TopicListItemSerializer, object: topic, scope: guardian(author))
      allow(author_serializer).to receive(:original_posters).and_return([poster])

      expect(author_serializer.posters.first.user.username).to eq(author.username)

      viewer_serializer = stubbed_serializer(TopicListItemSerializer, object: topic, scope: guardian(viewer))
      allow(viewer_serializer).to receive(:original_posters).and_return([poster])

      expect(viewer_serializer.posters.first.user.username).to eq(anon_user.username)
    end
  end

  describe "bookmarks and activity serializers" do
    it "anonymizes topic bookmark authors" do
      skip "UserTopicBookmarkSerializer is not available in this Discourse version" unless defined?(UserTopicBookmarkSerializer)

      topic, first_post, _anonymous_reply = anonymous_topic_with_owner_posts
      serializer = stubbed_serializer(UserTopicBookmarkSerializer, object: OpenStruct.new, scope: guardian(author))
      allow(serializer).to receive(:first_post).and_return(first_post)
      allow(serializer).to receive(:topic).and_return(topic)

      expect(serializer.bookmarkable_user.username).to eq(anon_user.username)
    end

    it "anonymizes post bookmark authors for explicit anonymous posts and anonymous topic owner posts" do
      skip "UserPostBookmarkSerializer is not available in this Discourse version" unless defined?(UserPostBookmarkSerializer)

      topic, first_post, anonymous_reply = anonymous_topic_with_owner_posts

      [first_post, anonymous_reply].each do |post|
        serializer = stubbed_serializer(UserPostBookmarkSerializer, object: OpenStruct.new, scope: guardian(author))
        allow(serializer).to receive(:post).and_return(post)
        allow(serializer).to receive(:topic).and_return(topic)

        expect(serializer.bookmarkable_user.username).to eq(anon_user.username)
      end
    end

    it "anonymizes user action author fields for liked anonymous author posts" do
      _topic, _first_post, anonymous_reply = anonymous_topic_with_owner_posts
      action = OpenStruct.new(post_id: anonymous_reply.id, target_post_id: anonymous_reply.id)
      serializer = stubbed_serializer(UserActionSerializer, object: action, scope: guardian(author))

      expect(serializer.username).to eq(anon_user.username)
      expect(serializer.name).to eq(anon_user.name)
      expect(serializer.avatar_template).to eq(anon_user.avatar_template)
      expect(serializer.user_id).to eq(anon_user.id)
    end

    it "writes symbol keys for fresh notification opts" do
      data = {}

      AnonymousNotificationData.apply!(data, key_style: :symbol)

      expect(data[:display_username]).to eq(anon_user.username)
      expect(data[:display_name]).to eq(anon_user.name)
      expect(data[:acting_user_id]).to eq(anon_user.id)
      expect(data[:user_id]).to eq(anon_user.id)
      expect(data).not_to have_key("display_username")
    end

    it "writes string keys for parsed notification JSON" do
      data = {}

      AnonymousNotificationData.apply!(data, key_style: :string)

      expect(data["display_username"]).to eq(anon_user.username)
      expect(data["display_name"]).to eq(anon_user.name)
      expect(data["acting_user_id"]).to eq(anon_user.id)
      expect(data["user_id"]).to eq(anon_user.id)
      expect(data).not_to have_key(:display_username)
    end

    it "anonymizes live notification alert payloads before push delivery" do
      topic, first_post, _anonymous_reply = anonymous_topic_with_owner_posts
      payload = {
        topic_id: topic.id,
        post_number: first_post.post_number,
        username: author.username,
        excerpt: "Reply text",
      }

      DiscourseEvent.trigger(:pre_notification_alert, viewer, payload)

      expect(payload[:username]).to eq(anon_user.username)
      expect(payload[:display_username]).to eq(anon_user.username)
    end

    it "anonymizes notification data for anonymous topic owner posts" do
      topic, first_post, _anonymous_reply = anonymous_topic_with_owner_posts
      notification =
        OpenStruct.new(
          topic_id: topic.id,
          post_number: first_post.post_number,
        )
      serializer = stubbed_serializer(NotificationSerializer, object: notification, scope: guardian(viewer))
      allow(serializer).to receive(:original_anonymous_post_data).and_return(
        {
          "display_username" => author.username,
          "username" => author.username,
          "original_username" => author.username,
          "acting_username" => author.username,
          "display_name" => author.name,
          "acting_user_id" => author.id,
          "user_id" => author.id,
          "topic_id" => topic.id,
          "post_number" => first_post.post_number,
          "excerpt" => "#{quote_raw(topic, first_post)} Reply text",
        },
      )

      data = serializer.data

      expect(data["display_username"]).to eq(anon_user.username)
      expect(data["username"]).to eq(anon_user.username)
      expect(data["original_username"]).to eq(anon_user.username)
      expect(data["acting_username"]).to eq(anon_user.username)
      expect(data["display_name"]).to eq(anon_user.name)
      expect(data["acting_user_id"]).to eq(anon_user.id)
      expect(data["user_id"]).to eq(anon_user.id)
      expect(data["excerpt"]).to include(%([quote="#{anon_user.username}, post:#{first_post.post_number}, topic:#{topic.id}"]))
      expect(data["excerpt"]).not_to include(author.username)
    end

    it "anonymizes raw quote usernames in notification text even when the notification post is not anonymous" do
      topic, first_post, _anonymous_reply = anonymous_topic_with_owner_posts
      normal_reply = fabricate_post(topic: topic, user: viewer, post_number: 3)
      notification =
        OpenStruct.new(
          topic_id: topic.id,
          post_number: normal_reply.post_number,
        )
      serializer = stubbed_serializer(NotificationSerializer, object: notification, scope: guardian(viewer))
      allow(serializer).to receive(:original_anonymous_post_data).and_return(
        {
          "display_username" => viewer.username,
          "topic_id" => topic.id,
          "post_number" => normal_reply.post_number,
          "excerpt" => "#{quote_raw(topic, first_post)} Normal reply",
        },
      )

      data = serializer.data

      expect(data["display_username"]).to eq(viewer.username)
      expect(data["excerpt"]).to include(%([quote="#{anon_user.username}, post:#{first_post.post_number}, topic:#{topic.id}"]))
      expect(data["excerpt"]).not_to include(author.username)
    end
  end

  describe "webhook serializers" do
    it "forces anonymous post author masking for webhook post payloads" do
      skip "WebHookPostSerializer is not available in this Discourse version" unless defined?(WebHookPostSerializer)

      _topic, first_post, _anonymous_reply = anonymous_topic_with_owner_posts
      serializer = WebHookPostSerializer.new(first_post, scope: guardian(Discourse.system_user), root: false)

      expect(serializer.username).to eq(anon_user.username)
      expect(serializer.name).to eq(anon_user.name)
      expect(serializer.user_id).to eq(anon_user.id)
      expect(serializer.avatar_template).to eq(anon_user.avatar_template)
    end

    it "patches at least one webhook topic field when the serializer exists" do
      skip "WebHookTopicViewSerializer is not available in this Discourse version" unless defined?(WebHookTopicViewSerializer)

      patched_methods =
        %i[
          original_anonymous_webhook_created_by
          original_anonymous_webhook_last_poster
          original_anonymous_webhook_user_id
        ].select { |method_name| WebHookTopicViewSerializer.method_defined?(method_name) }

      expect(patched_methods).not_to be_empty
    end
  end

  describe "RSS decorators and page titles" do
    it "returns anonymous users from RSS post decorators" do
      _topic, _first_post, anonymous_reply = anonymous_topic_with_owner_posts
      decorator = AnonymousRssPostDecorator.new(anonymous_reply, anon_user)

      expect(decorator.user.username).to eq(anon_user.username)
    end

    it "anonymizes cooked quote bodies in RSS post decorators" do
      topic, first_post, _anonymous_reply = anonymous_topic_with_owner_posts
      quoting_post =
        fabricate_post(
          topic: topic,
          user: viewer,
          post_number: 3,
          cooked: quote_html(topic, first_post),
        )
      decorator = AnonymousRssPostDecorator.new(quoting_post)

      expect_no_author_leak(decorator.cooked)
    end

    it "returns anonymous users from RSS topic decorators" do
      topic, _first_post, _anonymous_reply = anonymous_topic_with_owner_posts
      decorator = AnonymousRssTopicDecorator.new(topic, anon_user)

      expect(decorator.user.username).to eq(anon_user.username)
      expect(decorator).to be_a(Topic)
    end
  end
end
