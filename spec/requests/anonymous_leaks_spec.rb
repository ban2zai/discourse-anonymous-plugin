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
      SiteSetting.anonymous_post_enabled = false

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

  describe "интеграция с Solved" do
    before do
      skip "Требуется Solved с поддержкой нескольких решений" unless defined?(DiscourseSolved::AcceptedAnswersHelper)

      SiteSetting.solved_enabled = true
      SiteSetting.allow_solved_on_all_topics = true
      SiteSetting.solved_allow_multiple_solutions = true
      SiteSetting.accept_solutions_topic_author = true
      SiteSetting.show_who_marked_solved = true
      SiteSetting.enable_names = true
      SiteSetting.display_name_on_posts = true
      SiteSetting.solved_quote_length = 700
    end

    def change_solution(action, event, reply)
      messages =
        MessageBus.track_publish("/topic/#{reply.topic_id}") do
          post "/solution/#{action}.json", params: { id: reply.id }
        end

      expect(response).to have_http_status(:ok)
      matching = messages.select { |message| message.data[:type] == event }
      expect(matching.size).to eq(1)
      matching.first.data.as_json.fetch("accepted_answers")
    end

    def expect_solution_author(answer, user)
      expect(answer).to include(
        "username" => user.username,
        "name" => user.name,
        "avatar_template" => user.avatar_template,
      )
    end

    it "отдает поисковому роботу разметку решения с анонимным автором" do
      topic, _first_post, _quoting_post = anonymous_topic_with_quote
      reply = fabricate_post(topic: topic, user: author, post_number: 3)
      SiteSetting.solved_add_schema_markup = "answered only"

      DiscourseSolved.accept_answer!(reply, admin)
      get "/t/#{topic.slug}/#{topic.id}", headers: { "HTTP_USER_AGENT" => "Googlebot" }

      expect(response).to have_http_status(:ok)
      expect(response.body).to include('"acceptedAnswer"')
      expect_anonymous_body
    end

    it "исключает скрытое решение из общей рассылки при принятии и отмене" do
      topic, _first_post, visible_reply = anonymous_topic_with_quote
      hidden_text = "Содержимое скрытого решения"
      hidden_reply =
        fabricate_post(topic: topic, user: author, post_number: 3, cooked: "<p>#{hidden_text}</p>")

      sign_in(admin)
      change_solution(:accept, :accepted_solution, hidden_reply)
      hidden_reply.update_columns(hidden: true)

      broadcast = change_solution(:accept, :accepted_solution, visible_reply)
      expect(broadcast.pluck("id")).to eq([visible_reply.id])
      expect(broadcast.first["cooked"]).to include("Reply text")
      admin_answer = response.parsed_body.find { |answer| answer["id"] == hidden_reply.id }
      expect(admin_answer["cooked"]).to include(hidden_text)

      SiteSetting.anonymous_post_enabled = false
      expect(change_solution(:unaccept, :unaccepted_solution, visible_reply)).to be_nil
      expect(response.parsed_body.pluck("id")).to eq([hidden_reply.id])

      sign_in(author)
      reply = fabricate_post(topic: topic, user: author, post_number: 4)
      broadcast = change_solution(:accept, :accepted_solution, reply)
      expect_solution_author(broadcast.find { |answer| answer["id"] == reply.id }, anon_user)
    end

    it "скрывает анонимных авторов при загрузке темы и при изменении решений" do
      topic, _first_post, regular = anonymous_topic_with_quote
      anonymous = fabricate_post(topic: topic, user: author, post_number: 3)
      mark_anonymous_post(anonymous)
      unflagged = fabricate_post(topic: topic, user: author, post_number: 4)
      regular.update_columns(created_at: 3.minutes.ago)
      anonymous.update_columns(created_at: 2.minutes.ago)
      unflagged.update_columns(created_at: 1.minute.ago)

      sign_in(author)
      broadcast = change_solution(:accept, :accepted_solution, anonymous)
      expect(broadcast.pluck("id")).to eq([anonymous.id])
      expect_solution_author(broadcast.first, anon_user)
      expect(response.parsed_body).to eq(broadcast)
      expect(broadcast.first).to include(
        "accepter_username" => anon_user.username,
        "accepter_name" => anon_user.name,
      )

      sign_in(admin)
      change_solution(:accept, :accepted_solution, regular)
      broadcast = change_solution(:accept, :accepted_solution, unflagged)
      expect(broadcast.pluck("id")).to eq([regular.id, anonymous.id, unflagged.id])
      expect_solution_author(broadcast[0], viewer)
      expect_solution_author(broadcast[1], anon_user)
      expect_solution_author(broadcast[2], anon_user)
      expect(broadcast[2]["accepter_username"]).to eq(admin.username)
      expect(broadcast[0]["cooked"]).to include(%(data-username="#{anon_user.username}"))
      expect(broadcast.to_json).not_to include(author.username, author.name)
      expect_solution_author(response.parsed_body[1], author)
      expect_solution_author(response.parsed_body[2], author)

      get "/t/#{topic.slug}/#{topic.id}.json"
      expect(response).to have_http_status(:ok)
      answers = response.parsed_body.fetch("accepted_answers")
      expect_solution_author(answers[1], author)
      expect_solution_author(answers[2], author)
      expect(answers[1]["accepter_username"]).to eq(author.username)

      sign_in(viewer)
      get "/t/#{topic.slug}/#{topic.id}.json"
      expect(response).to have_http_status(:ok)
      answers = response.parsed_body.fetch("accepted_answers")
      expect(answers.pluck("id")).to eq([regular.id, anonymous.id, unflagged.id])
      expect_solution_author(answers[0], viewer)
      expect_solution_author(answers[1], anon_user)
      expect_solution_author(answers[2], anon_user)
      expect(answers.to_json).not_to include(author.username, author.name)

      sign_in(admin)
      broadcast = change_solution(:unaccept, :unaccepted_solution, regular)
      expect(broadcast.pluck("id")).to eq([anonymous.id, unflagged.id])
      broadcast.each { |answer| expect_solution_author(answer, anon_user) }
      expect(broadcast.first["accepter_username"]).to eq(anon_user.username)
      change_solution(:unaccept, :unaccepted_solution, anonymous)
      expect(change_solution(:unaccept, :unaccepted_solution, unflagged)).to be_nil
      expect(response.parsed_body).to be_nil
    end

    it "фильтрует анонимные решения из чужого профиля до пагинации" do
      topic = Fabricate(:topic, user: author, category: category)
      mark_anonymous_topic(topic)
      fabricate_post(topic: topic, user: author, post_number: 1)
      unflagged = fabricate_post(topic: topic, user: author, post_number: 2)

      other_topic = Fabricate(:topic, user: viewer, category: category)
      fabricate_post(topic: other_topic, user: viewer, post_number: 1)
      public_reply = fabricate_post(topic: other_topic, user: author, post_number: 2)
      anonymous = fabricate_post(topic: other_topic, user: author, post_number: 3)
      mark_anonymous_post(anonymous)

      sign_in(admin)
      change_solution(:accept, :accepted_solution, public_reply)
      DiscourseSolved::TopicAnswer.find_by!(answer_post_id: public_reply.id).update!(
        created_at: 1.minute.ago,
      )
      change_solution(:accept, :accepted_solution, anonymous)
      change_solution(:accept, :accepted_solution, unflagged)
      get "/solution/by_user.json", params: { username: author.username }
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body.fetch("user_solved_posts").pluck("post_id")).to contain_exactly(
        public_reply.id, anonymous.id, unflagged.id,
      )

      sign_in(viewer)
      get "/solution/by_user.json", params: { username: author.username, limit: 1 }
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body.fetch("user_solved_posts").pluck("post_id")).to eq([public_reply.id])

      SiteSetting.hide_user_activity_tab = true
      get "/solution/by_user.json", params: { username: author.username }
      expect(response).to have_http_status(:not_found)
    end
  end
end
