# frozen_string_literal: true

require "rails_helper"

describe "Создание анонимных публикаций", type: :request do
  fab!(:author) { Fabricate(:user, refresh_auto_groups: true) }
  fab!(:viewer) { Fabricate(:user, refresh_auto_groups: true) }
  fab!(:admin)
  fab!(:category)
  fab!(:anon_user) { Fabricate(:user, username: "anonymous") }

  before do
    SiteSetting.approve_post_count = 0
    SiteSetting.auto_silence_fast_typers_on_first_post = false
    SiteSetting.anonymous_post_enabled = true
    SiteSetting.anonymous_post_allowed_categories = category.id.to_s
    SiteSetting.anonymous_post_user = anon_user.username
    AnonymousPostHelper.reset_cache!
    sign_in(author)
  end

  def create_topic(**params)
    post "/posts.json",
         params: {
           title: "Тема для анонимного обсуждения",
           raw: "Первый пост для анонимного обсуждения",
           category: category.id,
           is_anonymous_post: 1,
         }.merge(params)
  end

  def expect_rejected_topic(error)
    expect { create_topic }.not_to change { [Topic.count, Post.count] }
    expect(response).to have_http_status(:unprocessable_entity)
    expect(response.parsed_body.fetch("errors")).to include(I18n.t(error))
  end

  def create_anonymous_topic
    create_topic
    expect(response.status).to eq(200), response.body
    Topic.find(response.parsed_body.fetch("topic_id"))
  end

  it "сохраняет тему и первый пост анонимными через API" do
    topic = create_anonymous_topic

    expect(topic.custom_fields["is_anonymous_topic"]).to eq(1)
    expect(topic.first_post.custom_fields["is_anonymous_post"]).to eq(1)
    expect(topic.first_post.user).to eq(author)
  end

  it "отклоняет анонимную публикацию в запрещенной категории" do
    SiteSetting.anonymous_post_allowed_categories = ""

    expect_rejected_topic(:anonymous_post_category_not_allowed)
  end

  it "отклоняет анонимную тему при выключенной настройке и принимает обычную" do
    SiteSetting.anonymous_post_enabled = false

    expect_rejected_topic(:anonymous_post_new_topics_disabled)
    create_topic(is_anonymous_post: 0)
    expect(response).to have_http_status(:ok)
    expect(Post.find(response.parsed_body.fetch("id")).custom_fields["is_anonymous_post"]).to be_nil
  end

  it "откатывает тему и пост, когда флаг поста не сохранился" do
    allow_any_instance_of(Post).to receive(:save_custom_fields).and_wrap_original do |save, *args, **kwargs|
      save.call(*args, **kwargs) unless save.receiver.custom_fields["is_anonymous_post"] == 1
    end

    expect_rejected_topic(:anonymous_post_save_failed)
  end

  it "откатывает тему и пост, когда флаг темы не сохранился" do
    allow_any_instance_of(Topic).to receive(:save_custom_fields).and_wrap_original do |save, *args, **kwargs|
      save.call(*args, **kwargs) unless save.receiver.custom_fields["is_anonymous_topic"] == 1
    end

    expect_rejected_topic(:anonymous_post_save_failed)
  end

  describe "Модерация темы" do
    def enqueue_topic
      category.update!(require_topic_approval: true)
      create_topic
      expect(response.status).to eq(200), response.body
      expect(response.parsed_body.fetch("action")).to eq("enqueued")
      ReviewableQueuedPost.find_by!(target_created_by: author)
    end

    it "сохраняет анонимность после одобрения" do
      queued = enqueue_topic
      expect(queued.payload.fetch("is_anonymous_post").to_i).to eq(1)
      expect(queued.perform(admin, :approve_post).success?).to eq(true)

      published = queued.reload.target
      expect(published.custom_fields["is_anonymous_post"]).to eq(1)
      expect(published.topic.custom_fields["is_anonymous_topic"]).to eq(1)
    end

    it "оставляет тему в очереди, если создание анонимных тем выключили" do
      queued = enqueue_topic
      SiteSetting.anonymous_post_enabled = false

      expect do
        expect(queued.perform(admin, :approve_post).success?).to eq(false)
      end.not_to change { [Topic.count, Post.count] }
      expect(queued.reload).to be_pending
    end
  end

  describe "Ответы в теме" do
    it "сохраняет ответ владельца без флага анонимным и скрывает его в общих событиях" do
      group = Fabricate(:group)
      group.add(author)
      category.set_permissions(group => :full)
      category.save!
      topic = create_anonymous_topic
      SiteSetting.anonymous_post_enabled = false
      SiteSetting.enable_names = false

      messages = MessageBus.track_publish("/topic/#{topic.id}") do
        post "/posts.json", params: { topic_id: topic.id, raw: "Новый анонимный ответ владельца темы" }
      end

      expect(response).to have_http_status(:ok)
      reply = Post.find(response.parsed_body.fetch("id"))
      expect(reply.user).to eq(author)
      expect(reply.custom_fields["is_anonymous_post"]).to eq(1)

      created = messages.find { |event| event.data[:type] == :created && event.data[:id] == reply.id }
      stats = messages.find { |event| event.data[:type] == :stats && event.data[:last_poster] }
      expect(created.data).to include(user_id: anon_user.id, username: anon_user.username, last_editor_id: anon_user.id)
      last_poster = stats.data.fetch(:last_poster).as_json
      expect(last_poster).to include("id" => anon_user.id, "username" => anon_user.username)
      expect(last_poster).not_to have_key("name")
      expect([created.data, stats.data].to_json).not_to include(author.username)
      [created, stats].each do |event|
        expect(event.group_ids).to match_array(topic.secure_group_ids)
        expect(event.group_ids).to include(group.id)
      end
    end

    it "оставляет обычный ответ другого участника именным" do
      topic = create_anonymous_topic
      SiteSetting.anonymous_post_enabled = false
      sign_in(viewer)

      messages = MessageBus.track_publish("/topic/#{topic.id}") do
        post "/posts.json", params: { topic_id: topic.id, raw: "Обычный ответ другого участника темы" }
      end

      expect(response).to have_http_status(:ok)
      reply = Post.find(response.parsed_body.fetch("id"))
      expect(reply.custom_fields["is_anonymous_post"]).to be_nil
      created = messages.map(&:data).find { |data| data[:type] == :created && data[:id] == reply.id }
      expect(created).to include(user_id: viewer.id, username: viewer.username)
      stats = messages.map(&:data).find { |data| data[:type] == :stats && data[:last_poster] }
      expect(stats.fetch(:last_poster).as_json).to include("id" => viewer.id, "username" => viewer.username)
    end

    it "отклоняет запрос анонимного ответа от другого участника" do
      topic = create_anonymous_topic
      sign_in(viewer)

      expect do
        post "/posts.json",
             params: { topic_id: topic.id, raw: "Запрос анонимного ответа другого участника", is_anonymous_post: 1 }
      end.not_to change(Post, :count)
      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body.fetch("errors")).to include(I18n.t(:anonymous_post_reply_not_allowed))
    end
  end

  it "после выключения сохраняет маскировку для читателя и доступ для разрешенной группы" do
    topic = create_anonymous_topic
    SiteSetting.anonymous_post_enabled = false
    group = Fabricate(:group)
    SiteSetting.anonymous_post_reveal_groups = group.id.to_s
    sign_in(viewer)

    get "/posts/#{topic.first_post.id}.json"
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body).to include("user_id" => anon_user.id, "username" => anon_user.username)

    group.add(viewer)
    get "/posts/#{topic.first_post.id}.json"
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body).to include("user_id" => author.id, "username" => author.username)

    sign_in(author)
    get "/t/#{topic.id}.json"
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body).to include("is_anonymous_topic" => 1, "user_id" => author.id)
  end
end
