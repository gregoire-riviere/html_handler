# HtmlHandler

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

The goal of this deps is to provide a very simple way to pre-compile raw html/CSS/JS on server side

## Principles

### Pre compile HTML content

__Exemple__ (index.html):
```html
<p>[Test]This is a mock![/Test]</p>
```

Given a map as follows 
```elixir
%{
  "Test" => "This is my text!"
}
```

It becomes (index.html) :
```html
<p>This is my text!</p>
```

### Use templates

You can also use html blocks like :
```html
<template src="path_to_the_file"/>
```
where the code of the html file will be injected in the html

### Others

Plus, this compiler takes care of minification of assets and put the compiled version in a dedicated directory

## Configuration

The configuration should be as follows :
```elixir
html_handler:
    [
        directories: %{
            html: "web/", # directory for html files
            js: "web/assets/js/", # directory for js files
            css: "web/assets/css/", # directory for css files
            # other directories to embed in the compile version
            dir_to_copy: ["web/assets/img", "web/assets/font"],
            #directory for the compiled version
            output: "web_build/",  
        },
        templatization?: true # flag to activate templates in html
    ]
```

## Usage

This simple command run the front compilation
```elixir
mix compile_front
```