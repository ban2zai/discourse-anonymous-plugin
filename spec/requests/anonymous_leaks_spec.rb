# frozen_string_literal: true

require "rails_helper"

describe "anonymous post leak endpoints", type: :request do
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

  def fabricate_post(topic:, user:, post_number:, raw: "Post text", cooked: "<p>Post text</p>")
    post = Fabricate(:post, topic: topic, user: user, post_number: post_number, raw: raw)
    post.update_columns(cooked: cooked)
    post.reload
  end

  def anonymous_topic_with_quote
    topic = Fabricate(:topic, user: author, category: category)
    mark_anonymous_topic(topic)

    first_post = fabricate_post(topic: topic, user: author, post_number: 1)
    mark_anonymous_post(first_post)

    quoted_raw = %([quote="#{author.username}, post:#{first_post.post_number}, topic:#{topic.id}"]Quoted text[/quote])
    quoted_cooked = <<~HTML
      <aside class="quote" data-username="#{author.username}" data-user-card="#{author.username}" data-post="#{first_post.post_number}" data-topic="#{topic.id}">
        <div class="title">
          <a href="/u/#{author.username}" data-user-card="#{author.username}">#{author.username}</a>:
        </div>
        <blockquote><p>Quoted text</p></blockquote>
      </aside>
      <p>Reply text</p>
    HTML

    quoting_post =
      fabricate_post(
        topic: topic,
        user: viewer,
        post_number: 2,
        raw: "#{quoted_raw}\nReply text",
        cooked: quoted_cooked,
      )

    [topic, first_post, quoting_post]
  end

  def expect_anonymous_body
    expect(response.body).to include(anon_user.username)
    expect(response.body).not_to include(author.username)
    expect(response.body).not_to include(author.name)
  end

  describe "raw markdown endpoints" do
    it "anonymizes quote headers on /raw/:topic_id/:post_number for regular users" do
      topic, _first_post, quoting_post = anonymous_topic_with_quote
      sign_in(viewer)

      get "/raw/#{topic.id}/#{quoting_post.post_number}"

      expect(response.status).to eq(200)
      expect_anonymous_body
    end

    it "anonymizes quote headers on /posts/:id/raw for regular users" do
      _topic, _first_post, quoting_post = anonymous_topic_with_quote
      sign_in(viewer)

      get "/posts/#{quoting_post.id}/raw"

      expect(response.status).to eq(200)
      expect_anonymous_body
    end

    it "keeps raw quote headers visible for admins" do
      topic, _first_post, quoting_post = anonymous_topic_with_quote
      sign_in(admin)

      get "/raw/#{topic.id}/#{quoting_post.post_number}"

      expect(response.status).to eq(200)
      expect(response.body).to include(author.username)
    end
  end

  describe "RSS feeds" do
    it "anonymizes creator and cooked quote bodies" do
      topic, _first_post, _quoting_post = anonymous_topic_with_quote

      get "/t/#{topic.slug}/#{topic.id}.rss"

      expect(response.status).to eq(200)
      expect_anonymous_body
    end
  end

  describe "crawler HTML" do
    it "does not expose real usernames to crawler layout" do
      topic, _first_post, _quoting_post = anonymous_topic_with_quote

      get "/t/#{topic.slug}/#{topic.id}", headers: { "HTTP_USER_AGENT" => "Googlebot" }

      expect(response.status).to eq(200)
      expect_anonymous_body
      expect(response.body).not_to include("/u/#{author.username}")
    end
  end
end
