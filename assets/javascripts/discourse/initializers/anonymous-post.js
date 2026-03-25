import { apiInitializer } from "discourse/lib/api";
import { iconHTML } from "discourse/lib/icon-library";
import { i18n } from "discourse-i18n";
import AnonymousPostCheckbox from "../components/anonymous-post-checkbox";

export default apiInitializer("0.4.0", (api) => {
  api.serializeOnCreate("is_anonymous_post");
  api.addTrackedPostProperties("is_anonymous_post");

  api.renderInOutlet("composer-after-save-or-cancel", AnonymousPostCheckbox);

  // Inject ghost icon color from site settings
  const siteSettings = api.container.lookup("service:site-settings");
  const ghostColor = siteSettings.anonymous_post_ghost_color || "#ffb900";
  const styleEl = document.createElement("style");
  styleEl.textContent = `.anon-post-indicator .d-icon, .anon-topic-icon .d-icon { color: ${ghostColor} !important; }`;
  document.head.appendChild(styleEl);

  api.addPostClassesCallback((attrs) => {
    return attrs.is_anonymous_post ? ["is-anonymous-post"] : [];
  });

  api.addPosterIcons((cfs, attrs) => {
    if (attrs.is_anonymous_post) {
      return [{ icon: "ghost", className: "anon-post-indicator", title: "anonymous_post.tooltip" }];
    }
    return [];
  });

  // Ghost icon left of topic title in topic list for anonymous topics
  api.registerValueTransformer("topic-list-item-class", ({ value, context }) => {
    if (context.topic.is_anonymous_topic) {
      value.push("is-anonymous-topic");
    }
    return value;
  });

  api.onPageChange((url) => {
    // Ghost icon for anonymous topics in topic list
    document.querySelectorAll("tr.is-anonymous-topic").forEach((row) => {
      if (row.querySelector(".anon-topic-icon")) return;
      const titleLink = row.querySelector(".link-top-line a.title");
      if (titleLink) {
        const icon = document.createElement("span");
        icon.className = "anon-topic-icon";
        icon.innerHTML = iconHTML("ghost");
        icon.title = i18n("anonymous_post.tooltip");
        titleLink.parentElement.insertBefore(icon, titleLink);
      }
    });

    // Hide profile sections for anonymous user
    const anonUsername = siteSettings.anonymous_post_user;
    if (anonUsername && url.match(new RegExp(`/u/${anonUsername}(/|$)`))) {
      document.body.classList.add("viewing-anon-profile");
    } else {
      document.body.classList.remove("viewing-anon-profile");
    }
  });
});
