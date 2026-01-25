# HtmlHandler

Requires Elixir 1.18 and Erlang/OTP 28.

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

## Configuration

```elixir
html_handler:
    [
        directories: %{
            html: "web/", # directory for html files
            js: "web/assets/js/", # directory for js files
            css: "web/assets/css/", # directory for css files
            # other directories to embed in the compile version
            dir_to_copy: ["web/assets/img", "web/assets/font"],
            # directory for the compiled version
            output: "web_build/",
        },
        templatization?: true, # flag to activate templates in html
        watch?: false # enable file watching to auto-compile
    ]
```

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
