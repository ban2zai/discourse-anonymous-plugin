# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Что это

Discourse-плагин для анонимных постов через чекбокс в композере — без переключения в режим анонима. Пользователь ставит чекбокс, пост публикуется от имени `anonymous` (настраивается), реальный автор скрыт от всех кроме admins и reveal_groups.

## Разработка

Плагин не имеет собственного build/test pipeline — он запускается внутри Discourse-окружения.

- **Тесты:** через Discourse core — `bin/rspec plugins/discourse-anonymous-plugin/`
- **JS:** компилируется Discourse автоматически (Ember/Glimmer)
- **SCSS:** компилируется Discourse автоматически
- **Локализации:** `config/locales/client.*.yml` и `server.*.yml`

## Архитектура

### Точка входа

[`plugin.rb`](plugin.rb) — манифест плагина. Регистрирует кастомные поля постов/топиков, загружает 13 модулей через `module.apply!(self)` паттерн.

### Настройки ([`config/settings.yml`](config/settings.yml))

- `anonymous_post_enabled` — мастер-переключатель
- `anonymous_post_allowed_categories` — whitelist категорий
- `anonymous_post_reveal_groups` — группы, видящие реальных авторов (default: `"1"` = admins)
- `anonymous_post_ghost_color` — цвет иконки-призрака
- `anonymous_post_user` — username для отображения (default: `"anonymous"`)

### Бэкенд ([`lib/anonymous_post/`](lib/anonymous_post/))

| Файл | Назначение |
|------|-----------|
| [`helper.rb`](lib/anonymous_post/helper.rb) | Ключевые методы: `anon_post_by_id?`, `can_reveal?`, preload кастомных полей |
| [`post_creation_handler.rb`](lib/anonymous_post/post_creation_handler.rb) | Валидация и сохранение флага `is_anonymous_post` при создании поста |
| [`post_serializers.rb`](lib/anonymous_post/post_serializers.rb) | Анонимизация username/avatar в BasicPostSerializer, PostSerializer, PostRevisionSerializer, cooked HTML (цитаты через Nokogiri) |
| [`topic_serializers.rb`](lib/anonymous_post/topic_serializers.rb) | Анонимизация автора топика в TopicViewDetailsSerializer, TopicListItemSerializer, RSS |
| [`topic_view_extensions.rb`](lib/anonymous_post/topic_view_extensions.rb) | RSS-фиды, page title |
| [`user_summary_extension.rb`](lib/anonymous_post/user_summary_extension.rb) | Скрытие анонимных постов из статистики профиля |
| [`user_action_filter.rb`](lib/anonymous_post/user_action_filter.rb) | Фильтрация UserAction стримов |
| [`search_filter.rb`](lib/anonymous_post/search_filter.rb) | Скрытие из `@username` поиска |
| [`notifications.rb`](lib/anonymous_post/notifications.rb) | Анонимизация отправителей уведомлений; redirect "send message" к модераторам |
| [`misc_serializers.rb`](lib/anonymous_post/misc_serializers.rb) | Закладки, @mention автокомплит |
| [`onebox_extension.rb`](lib/anonymous_post/onebox_extension.rb) | Превью топиков в композере |
| [`integration/reactions.rb`](lib/anonymous_post/integration/reactions.rb) | Интеграция с discourse-reactions |
| [`integration/solved.rb`](lib/anonymous_post/integration/solved.rb) | Интеграция с discourse-solved (включая JSON-LD schema) |

### Фронтенд ([`assets/`](assets/))

- [`javascripts/discourse/initializers/anonymous-post.js`](assets/javascripts/discourse/initializers/anonymous-post.js) — регистрация компонента, CSS-инъекция цвета иконки, отображение в списке топиков
- [`javascripts/discourse/components/anonymous-post-checkbox.gjs`](assets/javascripts/discourse/components/anonymous-post-checkbox.gjs) — Glimmer-компонент чекбокса в композере

### Поток данных

1. Пользователь ставит чекбокс → `is_anonymous_post: 1` сериализуется в форме
2. `post_creation_handler.rb` проверяет: категория в whitelist (новый топик) **или** топик анонимный + пользователь = автор топика (ответ)
3. Сохраняются кастомные поля: `posts.is_anonymous_post` и `topics.is_anonymous_topic`
4. Все сериализаторы проверяют `AnonymousPostHelper.anon_post_by_id?(post_id)` и подменяют данные автора

### Ключевые паттерны

- **Применение модулей:** `module.apply!(self)` в `plugin.rb`
- **N+1:** preload кастомных полей — центральная логика в `helper.rb`
- **Проверка прав:** `can_reveal?(guardian)` — используется повсеместно для admins/reveal_groups
- **Замена в HTML:** cooked-контент (цитаты) патчится через Nokogiri в `post_serializers.rb`
