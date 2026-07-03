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
  end

  describe "post serializers" do
    it "anonymizes post author fields for the anonymous author and regular users" do
      _topic, first_post, anonymous_reply = anonymous_topic_with_owner_posts

      [first_post, anonymous_reply].each do |post|
        [author, viewer].each do |user|
          serializer = PostSerializer.new(post, scope: guardian(user), root: false)

          expect(serializer.username).to eq(anon_user.username)
          expect(serializer.name).to eq("Anonymous")
          expect(serializer.display_username).to eq("Anonymous")
          expect(serializer.user_id).to eq(anon_user.id)
          expect(serializer.avatar_template).to eq(anon_user.avatar_template)
        end
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
      serializer = stubbed_serializer(TopicViewDetailsSerializer, object: details, scope: guardian(author))
      allow(serializer).to receive(:original_participants).and_return([author, viewer])

      created_by = serializer.created_by
      participants = serializer.participants
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

    it "hides topic user_id for anonymous topics from the author and regular users" do
      topic, _first_post, _anonymous_reply = anonymous_topic_with_owner_posts
      topic_view = OpenStruct.new(topic: topic)

      [author, viewer].each do |user|
        serializer = TopicViewSerializer.new(topic_view, scope: guardian(user), root: false)

        expect(serializer.user_id).to eq(nil)
      end
    end

    it "anonymizes topic list posters" do
      topic, _first_post, _anonymous_reply = anonymous_topic_with_owner_posts
      poster = OpenStruct.new(user: author)
      serializer = stubbed_serializer(TopicListItemSerializer, object: topic, scope: guardian(author))
      allow(serializer).to receive(:original_posters).and_return([poster])

      expect(serializer.posters.first.user.username).to eq(anon_user.username)
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
  end

  describe "RSS decorators and page titles" do
    it "returns anonymous users from RSS post decorators" do
      _topic, _first_post, anonymous_reply = anonymous_topic_with_owner_posts
      decorator = AnonymousRssPostDecorator.new(anonymous_reply, anon_user)

      expect(decorator.user.username).to eq(anon_user.username)
    end

    it "returns anonymous users from RSS topic decorators" do
      topic, _first_post, _anonymous_reply = anonymous_topic_with_owner_posts
      decorator = AnonymousRssTopicDecorator.new(topic, anon_user)

      expect(decorator.user.username).to eq(anon_user.username)
      expect(decorator).to be_a(Topic)
    end
  end
end
