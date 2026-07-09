# frozen_string_literal: true

module ::AnonymousPostsControllerExtension
  private

  def markdown(post)
    if SiteSetting.anonymous_post_enabled &&
       post &&
       guardian.can_see?(post) &&
       AnonymousPostHelper.hide_real_author?(guardian)
      render plain: AnonymousPostHelper.anonymize_raw_quotes(post.raw)
    else
      super
    end
  end
end

module AnonymousPost
  module RawEndpoints
    def self.apply!(_plugin)
      PostsController.prepend(AnonymousPostsControllerExtension) if defined?(PostsController)
    end
  end
end
