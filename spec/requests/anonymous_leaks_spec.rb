# frozen_string_literal: true

require "rails_helper"

describe "anonymous post leak endpoints", type: :request do
  fab!(:anon_user) { Fabricate(:user, username: "anonymous", name: "Anonymous") }
  fab!(:author) { Fabricate(:user, username: "doskochda", name: "DoskochDA") }
  fab!(:viewer) { Fabricate(:user, username: "regularviewer") }
  fab!(:admin) { Fabricate(:admin) }
  fab!(:reveal_group, :group)
  fab!(:revealer) { Fabricate(:user).tap { |user| reveal_group.add(user) } }
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

  describe "Адресат ответа" do
    let(:topic) { Fabricate(:topic, user: author, category: category) }
    let(:target) { fabricate_post(topic: topic, user: author, post_number: 1) }
    let(:reply) do
      fabricate_post(topic: topic, user: viewer, post_number: 2).tap do |post|
        post.update_columns(reply_to_post_number: target.post_number, reply_to_user_id: author.id)
      end
    end

    it "скрывает автора удаленного анонимного поста в адресате ответа" do
      mark_anonymous_post(target)
      reply_id = reply.id
      target.trash!(admin)

      sign_in(viewer)
      get "/posts/#{reply_id}.json"
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body.fetch("reply_to_user")).to include(
        "id" => anon_user.id, "username" => anon_user.username, "avatar_template" => anon_user.avatar_template,
      )

      sign_in(admin)
      get "/posts/#{reply_id}.json"
      expect(response.parsed_body.fetch("reply_to_user")).to include("id" => author.id, "username" => author.username)
    end

    it "маскирует адресата-владельца анонимной темы, когда исходный пост отсутствует" do
      mark_anonymous_topic(topic)
      reply.update_columns(reply_to_post_number: 99)
      sign_in(viewer)

      get "/posts/#{reply.id}.json"
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body.fetch("reply_to_user")).to include("id" => anon_user.id, "username" => anon_user.username)
    end

    it "сохраняет адресата обычного ответа, пока исходный пост подтверждает его" do
      sign_in(viewer)
      get "/posts/#{reply.id}.json"
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body.fetch("reply_to_user")).to include("id" => author.id, "username" => author.username)

      reply.update_columns(reply_to_post_number: nil)
      get "/posts/#{reply.id}.json"
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["reply_to_user"]).to be_nil
    end
  end

  describe "raw markdown endpoints" do
    it "маскирует подписи и цитаты в Markdown всей темы" do
      topic, first_post, quoting_post = anonymous_topic_with_quote
      legacy_post = fabricate_post(topic: topic, user: author, post_number: 3)
      SiteSetting.anonymous_post_enabled = false
      sign_in(viewer)

      get "/raw/#{topic.id}"
      expect(response).to have_http_status(:ok)
      expect_anonymous_body
      expect(response.body).to include(
        "#{anon_user.username} | #{first_post.updated_at} | #1",
        "#{viewer.username} | #{quoting_post.updated_at} | #2",
        "#{anon_user.username} | #{legacy_post.updated_at} | #3",
        %([quote="#{anon_user.username}, post:1, topic:#{topic.id}"]),
      )

      stub_const(PostsController, :MARKDOWN_TOPIC_PAGE_SIZE, 2) do
        get "/raw/#{topic.id}", params: { page: 2 }
        expect(response).to have_http_status(:ok)
        expect(response.body).to include("#{anon_user.username} | #{legacy_post.updated_at} | #3")
        expect(response.body).not_to include(" | #1")
      end

      sign_in(author)
      get "/raw/#{topic.id}"
      expect(response.body).to include("#{author.username} | #{first_post.updated_at} | #1")

      SiteSetting.anonymous_post_reveal_groups = reveal_group.id.to_s
      sign_in(revealer)
      get "/raw/#{topic.id}"
      expect(response.body).to include(%([quote="#{author.username}, post:1, topic:#{topic.id}"]))
    end

    it "маскирует профиль, аватар и цитату в штатном Markdown" do
      SiteSetting.enable_markdown_endpoints = true
      topic, _first_post, _quoting_post = anonymous_topic_with_quote
      path = "/t/#{topic.slug}/#{topic.id}.md"
      sign_in(viewer)

      get path
      expect(response).to have_http_status(:ok)
      expect(response.media_type).to eq("text/markdown")
      expect_anonymous_body
      expect(response.body).to include(
        anon_user.full_url,
        anon_user.avatar_template.gsub("{size}", "32"),
        viewer.full_url,
        "Quoted text",
      )
      expect(response.body).not_to include(
        author.full_url,
        author.avatar_template.gsub("{size}", "32"),
      )

      sign_in(admin)
      get path
      expect(response.body).to include(author.full_url)
    end

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

  describe "поиск по автору" do
    it "фильтрует анонимные результаты до группировки темы" do
      public_topic = Fabricate(:topic, user: author, category: category)
      anonymous_first = fabricate_post(topic: public_topic, user: author, post_number: 1)
      mark_anonymous_post(anonymous_first)
      named_reply = fabricate_post(topic: public_topic, user: author, post_number: 2)
      anonymous_topic = Fabricate(:topic, user: author, category: category)
      mark_anonymous_topic(anonymous_topic)
      legacy_post = fabricate_post(topic: anonymous_topic, user: author, post_number: 1)
      with_search_indexer_enabled do
        [anonymous_first, named_reply, legacy_post].each { |post| SearchIndexer.index(post, force: true) }
      end

      sign_in(viewer)
      [author.username, author.id].each do |identifier|
        get "/search.json", params: { q: "user:#{identifier}" }
        expect(response).to have_http_status(:ok)
        expect(response.parsed_body.fetch("posts").pluck("id")).to eq([named_reply.id])
      end

      get "/search.json", params: { q: "@#{author.username}" }
      expect(response).to have_http_status(:ok)
      expect(Array(response.parsed_body["posts"]).pluck("id")).not_to include(anonymous_first.id, legacy_post.id)

      sign_in(author)
      get "/search.json", params: { q: "user:#{author.username}" }
      expect(response.parsed_body.fetch("posts").pluck("id")).to include(legacy_post.id)

      SiteSetting.anonymous_post_reveal_groups = reveal_group.id.to_s
      sign_in(revealer)
      get "/search.json", params: { q: "user:#{author.id}" }
      expect(response.parsed_body.fetch("posts").pluck("id")).to include(legacy_post.id)
    end
  end

  describe "лента чужого профиля" do
    it "исключает анонимные посты из JSON и RSS до лимита" do
      public_topic = Fabricate(:topic, user: author, category: category)
      public_post = fabricate_post(topic: public_topic, user: author, post_number: 1)
      public_post.update_columns(created_at: 2.days.ago)
      explicit = fabricate_post(topic: public_topic, user: author, post_number: 2)
      mark_anonymous_post(explicit)
      anonymous_topic = Fabricate(:topic, user: author, category: category)
      mark_anonymous_topic(anonymous_topic)
      legacy_post = fabricate_post(topic: anonymous_topic, user: author, post_number: 1)
      timestamp = 1.day.ago
      Post.insert_all!(
        (2..51).map do |number|
          {
            topic_id: anonymous_topic.id,
            user_id: author.id,
            post_number: number,
            raw: "Скрытый пост",
            cooked: "<p>Скрытый пост</p>",
            post_type: Post.types[:regular],
            created_at: timestamp,
            updated_at: timestamp,
            last_version_at: timestamp,
          }
        end,
      )

      sign_in(viewer)
      get "/u/#{author.username}/activity.json"
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body.pluck("id")).to eq([public_post.id])

      get "/u/#{author.username}/activity.rss"
      expect(response).to have_http_status(:ok)
      expect(Nokogiri::XML(response.body).xpath("//item/link").map(&:text)).to eq([public_post.full_url])

      SiteSetting.anonymous_post_reveal_groups = reveal_group.id.to_s
      [author, revealer].each do |reader|
        sign_in(reader)
        get "/u/#{author.username}/activity.json"
        expect(response).to have_http_status(:ok)
        expect(response.parsed_body.pluck("id")).to include(explicit.id, legacy_post.id)
      end
    end
  end

  describe "авторы ссылок в теме" do
    it "скрывает ID для прямой и обратной ссылок из анонимного поста" do
      source_topic = Fabricate(:topic, user: author, category: category)
      mark_anonymous_topic(source_topic)
      source = fabricate_post(topic: source_topic, user: author, post_number: 1)
      visible = fabricate_post(topic: source_topic, user: revealer, post_number: 2)
      destination = Fabricate(:topic, user: viewer, category: category)
      target = fabricate_post(topic: destination, user: viewer, post_number: 1)

      direct = TopicLink.create!(
        topic: source_topic, post: source, user: author,
        url: "https://example.com/anonymous", domain: "example.com", clicks: 4,
      )
      named = TopicLink.create!(
        topic: source_topic, post: visible, user: revealer,
        url: "https://example.com/named", domain: "example.com", clicks: 2,
      )
      reflected = TopicLink.create!(
        topic: destination, post: target, user: author, link_topic: source_topic, link_post: source,
        url: source.full_url, domain: Discourse.current_hostname, clicks: 1, reflection: true, internal: true,
      )
      unattributed = TopicLink.create!(
        topic: destination, post: target, user: author, link_topic: source_topic,
        url: "#{source.full_url}?legacy=1", domain: Discourse.current_hostname,
        clicks: 2, reflection: true, internal: true,
      )

      sign_in(viewer)
      source_path = "/t/#{source_topic.slug}/#{source_topic.id}"
      get "#{source_path}.json"
      expect(response).to have_http_status(:ok)
      links = response.parsed_body.dig("details", "links")
      expect(links.pluck("url", "clicks")).to eq([[direct.url, 4], [named.url, 2]])
      expect(links.first).not_to have_key("user_id")
      expect(links.last.fetch("user_id")).to eq(revealer.id)

      get source_path
      preload = JSON.parse(Nokogiri::HTML(response.body).at_css("#data-preloaded").text)
      html_links = JSON.parse(preload.fetch("topic_#{source_topic.id}")).dig("details", "links")
      expect(html_links).to eq(links)

      destination_path = "/t/#{destination.slug}/#{destination.id}.json"
      get destination_path
      destination_links = response.parsed_body.dig("details", "links")
      expect(destination_links.pluck("url", "clicks")).to eq([[unattributed.url, 2], [reflected.url, 1]])
      destination_links.each { |link| expect(link).not_to have_key("user_id") }

      SiteSetting.anonymous_post_reveal_groups = reveal_group.id.to_s
      [author, revealer].each do |reader|
        sign_in(reader)
        get destination_path
        expect(response.parsed_body.dig("details", "links").pluck("user_id")).to eq([author.id, author.id])
      end
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
