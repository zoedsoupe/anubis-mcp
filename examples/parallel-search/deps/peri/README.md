# Peri

<!-- moduledoc:start -->
Peri is a data description library for Elixir, in the spirit of Clojure's
Plumatic Schema and Metosin's Malli. A schema is plain Elixir data: atoms
like `:string`, literals like `{:literal, 42}`, tuples, maps, keyword lists,
composed however the data demands. There is no separate DSL to learn; the
schema language is Elixir itself. Peri is data, Peri is Elixir.

Because schemas are data, they are programmable: the same definition can
validate structs, coerce string params at the boundary, generate test data,
export JSON Schema, build Ecto changesets, or render Phoenix forms.

## Installation

```elixir
defp deps do
  [
    {:peri, "~> 0.11.3"} # x-release-please-version
  ]
end
```

## Quick Start

```elixir
defmodule MyApp.Schemas do
  import Peri

  defschema :user, %{
    name: {:required, :string},
    age: {:integer, gte: 18},
    role: {:enum, [:admin, :user, :guest]}
  }

  defschema :search, %{
    page: {:coerce, :integer},
    tags: {:coerce, {:list, :string}, split: ","}
  }
end

MyApp.Schemas.user(%{name: "John", age: 25, role: :user})
# => {:ok, %{name: "John", age: 25, role: :user}}

# Boundary data arrives as strings; {:coerce, ...} types it.
MyApp.Schemas.search(%{"page" => "2", "tags" => "elixir,otp"})
# => {:ok, %{page: 2, tags: ["elixir", "otp"]}}
```
<!-- moduledoc:end -->

## Features

- **Data as schema**: type expressions are plain terms (`:string`,
  `{:list, t}`, `{:enum, [...]}`, `{:literal, v}`, tuples, maps) nested
  however the data demands
- **Boundary codecs**: `{:coerce, ...}` with `Peri.decode/3` and
  `Peri.encode/3` turns string params into typed data and back; targets
  include constrained scalars, enums, literals, and `split:`-separated lists
- **Validation modes**: strict by default, permissive when extra keys are fine
- **Errors**: per-field paths, custom `error:` overrides, i18n via
  `Peri.Error.traverse_errors/2`, Ecto-style rendering via
  `Peri.Error.humanize/1`
- **Schema algebra**: compose with `Peri.merge/2`, `select/2`, `except/2`;
  rewrite with `Peri.walk/2`; reuse with `{:ref, ...}`
- **Integrations**: Ecto changesets and custom types, Phoenix forms via
  `Peri.Phoenix.to_form/3`, JSON Schema Draft 7 in both directions
- **Data generation**: StreamData-backed `Peri.generate/1` with per-field
  `gen:` overrides
- **Metadata**: `{:meta, type, opts}` attaches docs and tooling hints without
  affecting validation

## Documentation

- **[Types Reference](pages/types.md)**: all types, constraints, coercion, and schema transformation
- **[Validation Patterns](pages/validation.md)**: modes, conditional and dependent validation, decoding/encoding, error handling
- **[Ecto Integration](pages/ecto.md)**: changesets and custom Ecto types
- **[Phoenix Integration](pages/phoenix.md)**: forms and params without Ecto
- **[Data Generation](pages/generation.md)**: sample data and property testing with StreamData
- **[JSON Schema](pages/json_schema.md)**: Draft 7 export and import
- **[Refs](pages/refs.md)**: recursive and cross-module schema references

## Why the Name "Peri"?

From the Greek "περί", meaning "around" or "about": the library wraps data
structures with descriptions of what they must conform to.
