# frozen_string_literal: true

require "rails_helper"

describe "anonymous post privacy" do
  fab!(:anon_user) { Fabricate(:user, username: "anonymous", name: "Anonymous") }
  fab!(:author) { Fabricate(:user, username: "doskochda", name: "DoskochDA") }
  fab!(:viewer) { Fabricate(:user) }
  fab!(:admin) { Fabricate(:admin) }
  fab!(:category)

  before do
    SiteSetting.anonymous_post_enabled = true
    SiteSetting.anonymous_post_user = anon_user.username
    AnonymousPostHelper.reset_cache!
  end

  def mark_anonymous_topic(topic)
    topic.custom_fields["is_anonymous_topic"] = 1
    topic.save_custom_fields(true)
  end

  def mark_anonymous_post(post)
    post.custom_fields["is_anonymous_post"] = 1
    post.save_custom_fields(true)
  end

  def quote_html(topic, quoted_post)
    <<~HTML
      <aside class="quote" data-username="#{author.username}" data-user-card="#{author.username}" data-post="#{quoted_post.post_number}" data-topic="#{topic.id}">
        <div class="title">
          <img src="/user_avatar/test/#{author.username}/45/1.png" alt="#{author.username}" title="#{author.username}">
          #{author.username}:
        </div>
        <blockquote><p>Quoted text</p></blockquote>
      </aside>
      <p>Reply text</p>
    HTML
  end

  def serialize_cooked(post, user)
    PostSerializer.new(post, scope: Guardian.new(user), root: false).cooked
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
    post
  end

  it "anonymizes a self quote of an anonymous reply for the author and regular users" do
    topic = Fabricate(:topic, user: author, category: category)
    mark_anonymous_topic(topic)

    quoted_post = fabricate_post(topic: topic, user: author, post_number: 2)
    mark_anonymous_post(quoted_post)

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

      expect(cooked).to include(%(data-username="#{anon_user.username}"))
      expect(cooked).to include(%(data-user-card="#{anon_user.username}"))
      expect(cooked).to include("#{anon_user.username}:")
      expect(cooked).not_to include(%(data-username="#{author.username}"))
      expect(cooked).not_to include(%(data-user-card="#{author.username}"))
      expect(cooked).not_to include("#{author.username}:")
      expect(cooked).not_to include("/#{author.username}/45/")
    end
  end

  it "anonymizes quotes of anonymous topic owner posts even without a post custom field" do
    topic = Fabricate(:topic, user: author, category: category)
    mark_anonymous_topic(topic)

    quoted_post = fabricate_post(topic: topic, user: author, post_number: 1)
    quoting_post =
      fabricate_post(
        topic: topic,
        user: viewer,
        post_number: 2,
        cooked: quote_html(topic, quoted_post),
      )

    cooked = serialize_cooked(quoting_post, viewer)

    expect(cooked).to include(%(data-username="#{anon_user.username}"))
    expect(cooked).not_to include(%(data-username="#{author.username}"))
    expect(cooked).not_to include("#{author.username}:")
  end

  it "keeps real quote data visible for admins" do
    topic = Fabricate(:topic, user: author, category: category)
    mark_anonymous_topic(topic)

    quoted_post = fabricate_post(topic: topic, user: author, post_number: 2)
    mark_anonymous_post(quoted_post)
    quoting_post =
      fabricate_post(
        topic: topic,
        user: author,
        post_number: 3,
        cooked: quote_html(topic, quoted_post),
      )

    cooked = serialize_cooked(quoting_post, admin)

    expect(cooked).to include(%(data-username="#{author.username}"))
    expect(cooked).to include("#{author.username}:")
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

    cooked = serialize_cooked(quoting_post, viewer)

    expect(cooked).to include(%(data-username="#{author.username}"))
    expect(cooked).to include("#{author.username}:")
  end

  it "anonymizes reply_to_user for anonymous author posts" do
    topic = Fabricate(:topic, user: author, category: category)
    mark_anonymous_topic(topic)

    replied_to_post = fabricate_post(topic: topic, user: author, post_number: 2)
    mark_anonymous_post(replied_to_post)
    reply =
      fabricate_post(
        topic: topic,
        user: author,
        post_number: 3,
        reply_to_post_number: replied_to_post.post_number,
      )

    [author, viewer].each do |user|
      reply_to_user = PostSerializer.new(reply, scope: Guardian.new(user), root: false).reply_to_user

      expect(reply_to_user[:username]).to eq(anon_user.username)
      expect(reply_to_user[:name]).to eq(anon_user.name)
      expect(reply_to_user[:id]).to eq(anon_user.id)
    end
  end
end
