import { getOwner } from "@ember/owner";
import { click, fillIn, visit } from "@ember/test-helpers";
import { test } from "qunit";
import User from "discourse/models/user";
import { presentUserIds } from "discourse/tests/helpers/presence-pretender";
import { acceptance } from "discourse/tests/helpers/qunit-helpers";

acceptance("Композер анонимной темы", function (needs) {
  needs.user();
  needs.settings({ anonymous_post_enabled: false, presence_enabled: true });
  needs.pretender((server, helper) => {
    server.get("/drafts/topic_280.json", () =>
      helper.response(200, { draft: null })
    );
  });

  async function openReply(context, isOwner) {
    await visit("/t/internationalization-localization/280");
    const user = User.current();
    user.set("user_option.hide_presence", false);
    const topic = getOwner(context).lookup("controller:topic").model;
    topic.setProperties({
      is_anonymous_topic: 1,
      user_id: isOwner ? user.id : user.id + 1,
    });
    await click("#topic-footer-buttons .btn.create");
  }

  test("У владельца есть отметка без чекбокса и скрыт индикатор набора", async function (assert) {
    await openReply(this, true);

    assert.dom(".anonymous-post-checkbox").exists();
    assert.dom(".anonymous-post-checkbox input").doesNotExist();
    await fillIn(".d-editor-input", "Анонимный ответ владельца темы.");
    assert.deepEqual(presentUserIds("/discourse-presence/reply/280"), []);
  });

  test("У другого участника есть обычный индикатор набора", async function (assert) {
    await openReply(this, false);

    assert.dom(".anonymous-post-checkbox").doesNotExist();
    await fillIn(".d-editor-input", "Именной ответ другого участника.");
    assert.deepEqual(presentUserIds("/discourse-presence/reply/280"), [
      User.current().id,
    ]);
  });
});
