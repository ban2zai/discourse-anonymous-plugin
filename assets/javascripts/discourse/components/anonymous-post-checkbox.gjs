import Component from "@glimmer/component";
import { on } from "@ember/modifier";
import { action } from "@ember/object";
import { getOwner } from "@ember/owner";
import { service } from "@ember/service";
import dIcon from "discourse/ui-kit/helpers/d-icon";
import { i18n } from "discourse-i18n";

export function isAnonymousReply(model, user) {
  return (
    model?.action === "reply" &&
    user &&
    model.topic?.is_anonymous_topic &&
    model.topic.user_id === user.id
  );
}

export default class AnonymousPostCheckbox extends Component {
  @service siteSettings;
  @service currentUser;

  get model() {
    return this.args.outletArgs?.model;
  }

  get checked() {
    return this.model?.get("is_anonymous_post") === 1;
  }

  get anonymousReply() {
    return isAnonymousReply(this.model, this.currentUser);
  }

  get showCheckbox() {
    if (this.model?.action !== "createTopic") {
      return false;
    }

    const { anonymous_post_enabled, anonymous_post_allowed_categories } =
      this.siteSettings;
    return (
      this.checked ||
      (anonymous_post_enabled &&
        this.model.categoryId &&
        anonymous_post_allowed_categories
          ?.split("|")
          .map(Number)
          .includes(this.model.categoryId))
    );
  }

  @action
  toggle(event) {
    const checked = event.target.checked;
    this.model.set("is_anonymous_post", checked ? 1 : 0);
    if (checked) {
      getOwner(this).lookup("service:composer-presence-manager")?.leave?.();
    }
  }

  <template>
    {{#if this.anonymousReply}}
      <span class="anonymous-post-checkbox">
        {{dIcon "ghost"}}
        {{i18n "anonymous_post.btn_label"}}
      </span>
    {{else if this.showCheckbox}}
      <div class="anonymous-post-checkbox">
        <label class="checkbox-label">
          <input
            checked={{this.checked}}
            type="checkbox"
            {{on "change" this.toggle}}
          />
          {{dIcon "ghost"}}
          {{i18n "anonymous_post.btn_label"}}
        </label>
      </div>
    {{/if}}
  </template>
}
