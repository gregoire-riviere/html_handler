# HtmlHandler

Requires Elixir 1.18 and Erlang/OTP 28.

## Table of contents
- [Installation](#installation)
- [Goal](#goal)
- [Features](#features)
- [Configuration (compiler)](#configuration-compiler)
- [Usage](#usage)
- [Plugs](#plugs)
  - [OutputStatic](#outputstatic)
  - [SSR](#ssr)
  - [Token](#token)
  - [RateLimit](#ratelimit)

## Installation

If [available in Hex](https://hex.pm/docs/publish), the package can be installed
by adding `html_handler` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:html_handler, "~> 1.0"}
  ]
end
```

Documentation can be generated with [ExDoc](https://github.com/elixir-lang/ex_doc)
and published on [HexDocs](https://hexdocs.pm). Once published, the docs can
be found at <https://hexdocs.pm/html_handler>.

## Goal

Provide a simple, server-side pre-compiler for raw HTML/CSS/JS with optional templating,
minification, and asset copying.

## Features

### HTML replacement (blocks)

**Example** (index.html):
```html
<p>[Test]This is a mock![/Test]</p>
```

Given a map:
```elixir
%{
  "Test" => "This is my text!"
}
```

It becomes (index.html):
```html
<p>This is my text!</p>
```

### HTML templates

Use inline templates to inject the content of another HTML file:
```html
<template src="path_to_the_file"/>
```
The referenced file is injected at compile time.

### Minification

HTML, CSS, and JS are minified during compilation (via `npx html-minifier`,
`npx minify`, and `npx uglify-js`).

### Asset copying

Copy extra directories (images, fonts, etc.) into the output folder.

### Output structure

The compiler creates:
- `output/html` for HTML
- `output/css` for CSS
- `output/js` for JS

If `seo?` is enabled, `sitemap.xml` and `robots.txt` are generated inside `output/seo`
and copied to the root of the build output.

## Configuration (compiler)

```elixir
[
  html_handler: [
    directories: %{
      html: "web/", # directory for html files
      js: "web/assets/js/", # directory for js files
      css: "web/assets/css/", # directory for css files
      # other directories to embed in the compile version
      dir_to_copy: ["web/assets/img", "web/assets/font"],
      # directory for the compiled version
      output: "web_build/"
    },
    templatization?: true, # flag to activate templates in html
    watch?: false, # enable file watching to auto-compile
    seo?: true, # generate sitemap.xml and robots.txt
    base_url: "https://example.com", # used by sitemap/robots and SSR fallback
    routes: %{
      "/home" => "index.html",
      "/blog" => "blog.html"
    }
  ]
]
```

Notes:
- `routes` and `base_url` are used when `seo?` is enabled.
- `base_url` is also used by the SSR plug when not provided in its options.

## Usage

Run the front compilation:
```elixir
mix compile_front
```

### Watch mode

To recompile automatically on file change:
```elixir
watch?: true
```
Then run:
```elixir
mix compile_front
```

### Install minifiers (global)

If the minifiers are not installed yet:
```elixir
mix install_minifiers
```

## Plugs

Each plug is optional and can be composed in your pipeline.

### OutputStatic

Serve the compiled output directory (including subfolders). Direct access to
`/html/...` or `*.html` is blocked unless declared in `routes`.

#### Example

```elixir
plug HTMLHandler.Plug.OutputStatic
```

Optional overrides:
```elixir
plug HTMLHandler.Plug.OutputStatic, at: "/assets", output: "web_build/"
```

Route HTML pages explicitly:
```elixir
plug HTMLHandler.Plug.OutputStatic,
  routes: %{
    "/home" => "index.html",
    "/blog" => "blog.html"
  }
```

This serves:
- `/home` -> `output/html/index.html`
- `/blog` -> `output/html/blog.html`

Routing notes:
- Static assets (css/js/images/fonts, etc.) remain accessible under the normal path.
- If you change `:at`, it scopes all static assets, including the HTML routes.
- `/sitemap.xml` and `/robots.txt` are served from the output root if present.

#### Configuration

| Option | Type | Default | Description |
| --- | --- | --- | --- |
| `output` | string | config `directories[:output]` or `"output"` | Root output directory. |
| `at` | string | `"/"` | Mount path for assets. |
| `routes` | map | `%{}` | Allowed HTML routes (`path` -> `file`). |
| `token_api` | boolean/keyword/map | `false` | Enable token API (see Token plug). |
| `gzip` | boolean | `false` | Forwarded to `Plug.Static`. |
| `brotli` | boolean | `false` | Forwarded to `Plug.Static`. |
| `cache_control_for_etags` | string/nil | `nil` | Forwarded to `Plug.Static`. |
| `cache_control_for_vsn_requests` | string/nil | `nil` | Forwarded to `Plug.Static`. |

### SSR

Intercept declared HTML routes, resolve fetch placeholders, call internal APIs,
and inject props into the HTML response. Place this plug before `OutputStatic`.

#### Example

```elixir
plug HTMLHandler.Plug.SSR,
  output: "web_build/",
  routes: %{
    "/home" => "index.html",
    "/blog" => "blog.html"
  },
  base_url: "http://localhost:4000"
```

#### Configuration

| Option | Type | Default | Description |
| --- | --- | --- | --- |
| `output` | string | config `directories[:output]` or `"output"` | Root output directory. |
| `routes` | map | `%{}` | Allowed HTML routes (`path` -> `file`). |
| `base_url` | string/nil | config `:base_url` | Base URL for internal fetches. |

#### Principe

1) Le HTML embarque une declaration JSON des fetchs a faire.
2) Le serveur lit ce JSON, resout les placeholders et appelle les endpoints.
3) Le serveur injecte les donnees dans la page sous forme JSON (props).
4) Le JS lit ces props et hydrate son etat.

#### Declaration des fetchs (dans le HTML)

Exemple a poser dans un template (fichier HTML) :
```html
<script id="__ssr_fetch" type="application/json">
{
  "fetches": [
    { "key": "user", "url": "/api/user?id=[user_id]" },
    { "key": "posts", "url": "/api/posts?limit=5" }
  ]
}
</script>
```

- `key` : nom de la prop cote client.
- `url` : endpoint a appeler cote serveur.
- Les placeholders entre `[]` sont resolus par le serveur (params/cookies/etc).

#### Injection des props dans le HTML

Le serveur doit injecter un JSON de props dans un bloc `application/json` :
```html
<script id="__props" type="application/json">[ssr_props_json]</script>
```

Important : remplacer `</` par `<\/` dans le JSON pour ne pas casser le script.

#### Consommation cote JS

```js
const el = document.getElementById("__props");
const props = JSON.parse(el?.textContent || "{}");
// props.user, props.posts, ...
```

#### Placeholders disponibles

Dans les URLs declarees, tu peux utiliser des placeholders :
- `[user_id]` : cherche dans query params, cookies, assigns, puis props deja calculees.
- `[cookie.user_id]` : force la source cookies.
- `[query.page]` : force la source query params.
- `[assign.user_id]` : force la source assigns.
- `[prop.user.id]` : utilise une prop precedente (dependances entre fetchs).

Les fetchs sont executes dans l'ordre du JSON.

### Token

Emet et verifie des tokens. Le plug tente d'abord de servir l'API de generation,
puis verifie le token sur les autres routes.

#### Example

```elixir
plug HTMLHandler.Plug.Token,
  path: "/api/token",
  ttl: 3600,
  required: true
```

Tu peux aussi activer uniquement l'API via `OutputStatic` :
```elixir
plug HTMLHandler.Plug.OutputStatic,
  token_api: [path: "/api/token", ttl: 3600]
```

#### Configuration

| Option | Type | Default | Description |
| --- | --- | --- | --- |
| `path` | string | `"/api/token"` | URL de l'endpoint de generation. |
| `ttl` | integer | `3600` | Duree de vie du token en secondes. |
| `user_param` | string | `"user"` | Parametre `user` (query ou JSON). |
| `token_param` | string | `"token"` | Parametre `token` (query). |
| `required` | boolean | `true` | Si `false`, un token manquant est accepte. |
| `data_dir` | string/nil | config `directories[:data]` ou `"data"` | Dossier du secret. |

Notes:
- Pour desactiver l'API, passe `false` (ou `nil`) comme options du plug.
- Pour ne pas forcer la verif du token, utilise `required: false`.

### RateLimit

Limite le nombre de requetes par IP. Le plug maintient un petit etat en ETS et
peut persister la configuration.

#### Example

Place le plug avant les plugs qui servent les pages:
```elixir
plug HTMLHandler.Plug.RateLimit,
  limit: 100,
  window_ms: 60_000,
  trust_x_forwarded_for: true,
  allowlist: ["127.0.0.1"]
```

#### Configuration

| Option | Type | Default | Description |
| --- | --- | --- | --- |
| `enabled` | boolean | `true` | Active le rate limit. |
| `limit` | integer | `60` | Nombre de requetes autorisees par fenetre. |
| `window_ms` | integer | `60_000` | Taille de la fenetre en millisecondes. |
| `trust_x_forwarded_for` | boolean | `false` | Utilise `x-forwarded-for` pour l'IP client. |
| `allowlist` | list | `[]` | Liste d'IPs exemptes (strings ou tuples IP). |
| `status` | integer | `429` | Status HTTP en cas de blocage. |
| `response_body` | binary | `"rate_limited"` | Body de la reponse en cas de blocage. |
| `response_headers` | list | `[{"content-type","text/plain"}]` | Headers supplementaires. |
| `cleanup_interval_ms` | integer | `60_000` | Frequence de nettoyage ETS. |
| `persist_config?` | boolean | `true` | Persiste la config en ETS. |
| `table` | atom | `:html_handler_rate_limit` | Nom de la table ETS. |

Notes:
- Le plug ajoute un header `retry-after` (en secondes) quand il bloque une requete.
- Tu peux modifier la config a chaud via `HTMLHandler.Plug.RateLimit.put_config/1`.
