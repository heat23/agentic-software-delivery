# Blog Content Storage Policy (extracted from _v-core.md)

_Last reviewed: 2026-07-05 (ecosystem review sweep)._

## Blog Content Storage Policy

All blog articles and content pages are **file-based Markdown** (`.md` files with YAML frontmatter), rendered directly from the filesystem. Never create database-backed blog content:
- No `BlogSeeder`, `ArticleSeeder`, or content seeders that embed article text in PHP
- No `Blog` or `Article` Eloquent models for storing post content in the database
- No blog/article migrations that create content tables
- No CMS-style content storage in the database

Each article is a standalone `.md` file in the project's content directory (e.g., `content/blog/`, `content/compare/` for competitor-comparison pages, `blog/`, `resources/content/`). Visual assets (SVG, JSX, Mermaid) live alongside the article in a subdirectory named after the slug.

This applies to all skills that generate blog content (`v-content-create`, `v-interactive-showcase`, `v-scaffold`, `v-build`).
