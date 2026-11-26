# frozen_string_literal: true

module ::AnonymousPostsControllerExtension
  def user_posts_feed
    params.require(:username)
    user = fetch_user_from_params
    raise Discourse::NotFound unless guardian.can_see_profile?(user)

    posts = Post.public_posts.visible.where(user_id: user.id, post_type: Post.types[:regular])
    posts = AnonymousPostHelper.without_anonymous_authors(posts, guardian)
    posts = posts.order(created_at: :desc).includes(:user, topic: :category).limit(50)
    posts = posts.select { |post| guardian.can_see?(post) && post.topic.present? }

    respond_to do |format|
      format.rss do
        @posts = posts
        @description = I18n.t("rss_description.user_posts", username: user.username)
        @title = "#{SiteSetting.title} - #{@description}"
        @link = "#{user.full_url}/activity"
        render "posts/latest", formats: [:rss]
      end

      format.json do
        render_json_dump(
          serialize_data(
            posts,
            PostSerializer,
            scope: guardian,
            add_excerpt: true,
            ignored_user_like_counts: PostAction.ignored_user_like_counts_for(posts, current_user),
          ),
        )
      end
    end
  end

  private

  def markdown(post)
    if post && guardian.can_see?(post) && AnonymousPostHelper.hide_real_author?(guardian)
      render plain: AnonymousPostHelper.anonymize_raw_quotes(post.raw)
    else
      super
    end
  end

  def markdown_for_topic
    return super unless AnonymousPostHelper.hide_real_author?(guardian)

    view = TopicView.new(
      params[:topic_id],
      current_user,
      page: params[:page],
      limit: PostsController::MARKDOWN_TOPIC_PAGE_SIZE,
    )
    add_topic_noindex_header(view.topic)
    posts = view.posts.select { |post| guardian.can_see?(post) }
    anonymous_ids = AnonymousPostHelper.anonymous_author_post_ids(posts, view.topic)
    quote_targets =
      AnonymousPostHelper.anon_quote_targets(
        posts.flat_map { |post| AnonymousPostHelper.raw_quote_pairs(post.raw) },
      )

    posts.map do |post|
      username = post.user.username
      if anonymous_ids.include?(post.id) && guardian.user&.id != post.user_id
        username = AnonymousPostHelper.anon_username
      end
      raw = AnonymousPostHelper.anonymize_raw_quotes(post.raw, targets: quote_targets)
      "#{username} | #{post.updated_at} | ##{post.post_number}\n\n#{raw}\n\n-------------------------\n\n"
    end.join
  end
end

module ::AnonymousMarkdownTopicRendererExtension
  private

  def visible_posts
    posts = super
    return posts unless AnonymousPostHelper.hide_real_author?(@guardian)

    anonymous_ids = AnonymousPostHelper.anonymous_author_post_ids(posts, @topic)
    posts.map do |post|
      if anonymous_ids.include?(post.id) && @guardian.user&.id != post.user_id
        AnonymousPostUserDecorator.new(post, anonymous_markdown_user)
      else
        post
      end
    end
  end

  def anonymous_markdown_user
    @anonymous_markdown_user ||=
      AnonymousPostHelper.anonymous_user ||
        AnonymousPostHelper.anonymous_user_object.tap do |user|
          user.full_url = "#{Discourse.base_url}/u/#{ERB::Util.url_encode(user.username)}"
        end
  end
end

module AnonymousPost
  module RawEndpoints
    def self.apply!(_plugin)
      PostsController.prepend(AnonymousPostsControllerExtension) if defined?(PostsController)
      if defined?(MarkdownEndpoint::TopicRenderer)
        MarkdownEndpoint::TopicRenderer.prepend(AnonymousMarkdownTopicRendererExtension)
      end
    end
  end
end
